import Foundation

public enum ExecutionResultStatus: String, Sendable {
    case completed
    case failed
    case cancelled
}

public struct ExecutionResult: Equatable, Sendable {
    public let status: ExecutionResultStatus
    public let exitCode: Int32?
    public let stdout: String
    public let stderr: String
    public let truncated: Bool
    public let durationMilliseconds: Int
    public let redactions: Int

    public init(
        status: ExecutionResultStatus,
        exitCode: Int32?,
        stdout: String,
        stderr: String,
        truncated: Bool,
        durationMilliseconds: Int,
        redactions: Int
    ) {
        self.status = status
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.truncated = truncated
        self.durationMilliseconds = durationMilliseconds
        self.redactions = redactions
    }

    public var protocolObject: [String: Any] {
        [
            "exit_code": exitCode.map { Int($0) as Any } ?? NSNull(),
            "stdout": stdout,
            "stderr": stderr,
            "truncated": truncated,
            "duration_ms": durationMilliseconds,
            "redactions": redactions,
        ]
    }
}

public final class BoundedOutputWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private(set) var truncated = false

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - storage.count)
        if data.count > remaining { truncated = true }
        storage.append(data.prefix(remaining))
    }

    public func snapshot() -> (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, truncated)
    }
}

public struct HostileOutputSanitizer: Sendable {
    public struct Sanitized: Equatable, Sendable {
        public let text: String
        public let redactions: Int
    }

    private static let secretPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*['"]?([A-Za-z0-9_./+=-]{8,})"#),
        try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        try! NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9_-]{20,}\b"#),
        try! NSRegularExpression(pattern: #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
    ]

    public init() {}

    public func sanitize(_ data: Data, allowSensitiveDisclosure: Bool) -> Sanitized {
        var scalarSafe = String(decoding: data, as: UTF8.self)
        scalarSafe = stripControlAndTerminalSequences(scalarSafe)
        guard !allowSensitiveDisclosure else {
            return Sanitized(text: scalarSafe, redactions: 0)
        }

        var redactions = 0
        for expression in Self.secretPatterns {
            let range = NSRange(scalarSafe.startIndex..., in: scalarSafe)
            let matches = expression.matches(in: scalarSafe, range: range)
            redactions += matches.count
            scalarSafe = expression.stringByReplacingMatches(
                in: scalarSafe,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return Sanitized(text: scalarSafe, redactions: redactions)
    }

    private func stripControlAndTerminalSequences(_ input: String) -> String {
        var result = input.replacingOccurrences(
            of: #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\))"#,
            with: "",
            options: .regularExpression
        )
        result.removeAll { character in
            character.unicodeScalars.contains {
                ($0.value < 0x20 && $0 != "\n" && $0 != "\r" && $0 != "\t")
                    || $0.value == 0x7f
                    || (0x202a...0x202e).contains($0.value)
                    || (0x2066...0x2069).contains($0.value)
            }
        }
        return result
    }
}
