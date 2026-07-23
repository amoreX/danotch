import CryptoKit
import Foundation

public enum ExecutorJSON: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([ExecutorJSON])
    case object([String: ExecutorJSON])
    case null

    public init(any value: Any) throws {
        switch value {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .boolean(value.boolValue)
                return
            }
            guard Double(value.intValue) == value.doubleValue else {
                throw LocalActionError.invalidSchema("Only integral JSON numbers are supported")
            }
            self = .integer(value.intValue)
        case let value as Bool:
            self = .boolean(value)
        case let value as [Any]:
            self = .array(try value.map(ExecutorJSON.init(any:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(ExecutorJSON.init(any:)))
        case _ as NSNull:
            self = .null
        default:
            throw LocalActionError.invalidSchema("Unsupported JSON value")
        }
    }

    public var any: Any {
        switch self {
        case .string(let value): return value
        case .integer(let value): return value
        case .boolean(let value): return value
        case .array(let value): return value.map(\.any)
        case .object(let value): return value.mapValues(\.any)
        case .null: return NSNull()
        }
    }

    public var postgresJSON: String {
        switch self {
        case .string(let value):
            let data = try! JSONSerialization.data(withJSONObject: [value])
            return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .array(let value): return "[\(value.map(\.postgresJSON).joined(separator: ", "))]"
        case .object(let value):
            let members = value.keys.sorted().map {
                ExecutorJSON.string($0).postgresJSON + ": " + value[$0]!.postgresJSON
            }
            return "{" + members.joined(separator: ", ") + "}"
        case .null: return "null"
        }
    }
}

public enum LocalActionError: Error, Equatable, LocalizedError {
    case registryVersion
    case unknownAction
    case invalidSchema(String)
    case invalidBinding(String)
    case expired
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .registryVersion: return "The local action registry version is unsupported."
        case .unknownAction: return "The local action is not registered."
        case .invalidSchema(let reason): return "The local action schema is invalid: \(reason)"
        case .invalidBinding(let reason): return "The execution grant binding is invalid: \(reason)"
        case .expired: return "The execution grant expired before startup."
        case .unsupported: return "Local execution requires macOS 26 on Apple silicon."
        }
    }
}

public struct ExecutionLimits: Hashable, Sendable {
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let diskBytes: UInt64
    public let processCount: Int
    public let outputBytes: Int
    public let timeoutSeconds: Int

    public init(json: ExecutorJSON) throws {
        guard case .object(let value) = json,
              Set(value.keys) == Set([
                "cpu_count", "memory_bytes", "disk_bytes", "process_count",
                "output_bytes", "timeout_seconds",
              ]),
              case .integer(let cpu) = value["cpu_count"],
              case .integer(let memory) = value["memory_bytes"],
              case .integer(let disk) = value["disk_bytes"],
              case .integer(let processes) = value["process_count"],
              case .integer(let output) = value["output_bytes"],
              case .integer(let timeout) = value["timeout_seconds"],
              (1...4).contains(cpu),
              (128 * 1_024 * 1_024...4 * 1_024 * 1_024 * 1_024).contains(memory),
              (256 * 1_024 * 1_024...8 * 1_024 * 1_024 * 1_024).contains(disk),
              (1...256).contains(processes),
              (1...4 * 1_024 * 1_024).contains(output),
              (1...1_800).contains(timeout) else {
            throw LocalActionError.invalidSchema("resource limits are missing, excessive, or malformed")
        }
        cpuCount = cpu
        memoryBytes = UInt64(memory)
        diskBytes = UInt64(disk)
        processCount = processes
        outputBytes = output
        timeoutSeconds = timeout
    }

    public var json: ExecutorJSON {
        .object([
            "cpu_count": .integer(cpuCount),
            "memory_bytes": .integer(Int(memoryBytes)),
            "disk_bytes": .integer(Int(diskBytes)),
            "process_count": .integer(processCount),
            "output_bytes": .integer(outputBytes),
            "timeout_seconds": .integer(timeoutSeconds),
        ])
    }
}

public struct ExecutionCapabilities: Hashable, Sendable {
    public enum WorkspaceMode: String, Sendable { case readOnly = "read_only", readWrite = "read_write" }

    public let workspaceMode: WorkspaceMode
    public let egressDestinations: [String]
    public let sensitiveFileAccess: Bool
    public let sensitiveOutputDisclosure: Bool
    public let resultUpload: Bool
    public let limits: ExecutionLimits

    public init(json: ExecutorJSON) throws {
        guard case .object(let value) = json,
              Set(value.keys) == Set([
                "workspace_mode", "egress_destinations", "sensitive_file_access",
                "sensitive_output_disclosure", "result_upload", "limits",
              ]),
              case .string(let modeValue) = value["workspace_mode"],
              let mode = WorkspaceMode(rawValue: modeValue),
              case .array(let destinationsValue) = value["egress_destinations"],
              case .boolean(let sensitiveFiles) = value["sensitive_file_access"],
              case .boolean(let sensitive) = value["sensitive_output_disclosure"],
              case .boolean(let upload) = value["result_upload"],
              let limitsValue = value["limits"] else {
            throw LocalActionError.invalidSchema("capabilities do not match registry v1")
        }
        let destinations = try destinationsValue.map { item -> String in
            guard case .string(let destination) = item,
                  Self.isValidDestination(destination) else {
                throw LocalActionError.invalidSchema("egress destinations must be exact HTTPS host:port values")
            }
            return destination.lowercased()
        }
        guard Set(destinations).count == destinations.count else {
            throw LocalActionError.invalidSchema("duplicate egress destination")
        }
        workspaceMode = mode
        egressDestinations = destinations.sorted()
        sensitiveFileAccess = sensitiveFiles
        sensitiveOutputDisclosure = sensitive
        resultUpload = upload
        limits = try ExecutionLimits(json: limitsValue)
    }

    public var json: ExecutorJSON {
        .object([
            "workspace_mode": .string(workspaceMode.rawValue),
            "egress_destinations": .array(egressDestinations.map(ExecutorJSON.string)),
            "sensitive_file_access": .boolean(sensitiveFileAccess),
            "sensitive_output_disclosure": .boolean(sensitiveOutputDisclosure),
            "result_upload": .boolean(resultUpload),
            "limits": limits.json,
        ])
    }

    private static func isValidDestination(_ value: String) -> Bool {
        guard !value.contains("/"), !value.contains("@"), !value.contains("*"),
              let separator = value.lastIndex(of: ":"),
              Int(value[value.index(after: separator)...]).map({ (1...65535).contains($0) }) == true else {
            return false
        }
        let host = value[..<separator]
        return !host.isEmpty && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}

public struct RegisteredLocalAction: Hashable, Sendable {
    public let name: String
    public let displayName: String
    public let highRiskShell: Bool
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
}

public struct LocalActionRegistry: Sendable {
    public static let version = "1"
    public static let shared = LocalActionRegistry()

    public init() {}

    public func resolve(
        registryVersion: String,
        name: String,
        parameters: ExecutorJSON,
        capabilities: ExecutionCapabilities
    ) throws -> RegisteredLocalAction {
        guard registryVersion == Self.version else { throw LocalActionError.registryVersion }
        guard case .object(let values) = parameters else {
            throw LocalActionError.invalidSchema("parameters must be an object")
        }

        switch name {
        case "workspace.inspect":
            try exact(values, ["path", "depth"])
            let path = try relativePath(values["path"])
            let depth = try integer(values["depth"], range: 1...8)
            return .init(
                name: name, displayName: "Inspect workspace", highRiskShell: false,
                executable: "/usr/bin/find",
                arguments: [path, "-xdev", "-maxdepth", String(depth), "-print"],
                workingDirectory: "/workspace"
            )
        case "workspace.search":
            try exact(values, ["query", "path", "max_results"])
            let query = try nonEmptyString(values["query"], maximum: 500)
            let path = try relativePath(values["path"])
            let maximum = try integer(values["max_results"], range: 1...1_000)
            return .init(
                name: name, displayName: "Search workspace", highRiskShell: false,
                executable: "/bin/grep",
                arguments: ["-R", "-n", "-I", "-m", String(maximum), "--", query, path],
                workingDirectory: "/workspace"
            )
        case "workspace.read_file":
            try exact(values, ["path", "max_bytes"])
            let path = try relativePath(values["path"])
            let bytes = try integer(values["max_bytes"], range: 1...capabilities.limits.outputBytes)
            return .init(
                name: name, displayName: "Read workspace file", highRiskShell: false,
                executable: "/usr/bin/head", arguments: ["-c", String(bytes), "--", path],
                workingDirectory: "/workspace"
            )
        case "workspace.run_tests":
            try exact(values, ["runner", "arguments"])
            let runner = try nonEmptyString(values["runner"], maximum: 20)
            let args = try stringArray(values["arguments"], maximumCount: 20, maximumLength: 200)
            let executable: String
            switch runner {
            case "swift": executable = "/usr/bin/swift"
            case "npm": executable = "/usr/bin/npm"
            default: throw LocalActionError.invalidSchema("runner is not allowlisted")
            }
            guard args.allSatisfy({ !$0.contains("\0") && $0 != "--prefix" && $0 != "--global" }) else {
                throw LocalActionError.invalidSchema("test arguments contain a forbidden option")
            }
            return .init(
                name: name, displayName: "Run \(runner) tests", highRiskShell: false,
                executable: executable, arguments: ["test"] + args, workingDirectory: "/workspace"
            )
        case "shell.execute":
            try exact(values, ["command"])
            let command = try nonEmptyString(values["command"], maximum: 4_096)
            guard !command.contains("\0") else {
                throw LocalActionError.invalidSchema("shell command contains NUL")
            }
            return .init(
                name: name, displayName: "Run exact shell command", highRiskShell: true,
                executable: "/bin/sh", arguments: ["-lc", command], workingDirectory: "/workspace"
            )
        default:
            throw LocalActionError.unknownAction
        }
    }

    public func actionHash(registryVersion: String, name: String, parameters: ExecutorJSON) -> String {
        Self.sha256("\(registryVersion)\n\(name)\n\(parameters.postgresJSON)")
    }

    public func parametersHash(_ parameters: ExecutorJSON) -> String {
        Self.sha256(parameters.postgresJSON)
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func exact(_ values: [String: ExecutorJSON], _ keys: Set<String>) throws {
        guard Set(values.keys) == keys else {
            throw LocalActionError.invalidSchema("parameters must contain exactly \(keys.sorted())")
        }
    }

    private func relativePath(_ value: ExecutorJSON?) throws -> String {
        let path = try nonEmptyString(value, maximum: 1_024)
        guard path != ".", !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw LocalActionError.invalidSchema("path must be a normalized workspace-relative path")
        }
        return path
    }

    private func nonEmptyString(_ value: ExecutorJSON?, maximum: Int) throws -> String {
        guard case .string(let string) = value,
              !string.isEmpty, string.utf8.count <= maximum else {
            throw LocalActionError.invalidSchema("string is empty or too long")
        }
        return string
    }

    private func integer(_ value: ExecutorJSON?, range: ClosedRange<Int>) throws -> Int {
        guard case .integer(let number) = value, range.contains(number) else {
            throw LocalActionError.invalidSchema("integer is outside its allowed range")
        }
        return number
    }

    private func stringArray(
        _ value: ExecutorJSON?,
        maximumCount: Int,
        maximumLength: Int
    ) throws -> [String] {
        guard case .array(let values) = value, values.count <= maximumCount else {
            throw LocalActionError.invalidSchema("argument array is too large")
        }
        return try values.map { try nonEmptyString($0, maximum: maximumLength) }
    }
}
