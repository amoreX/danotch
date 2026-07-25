import Combine
import Foundation

enum UpdateLaunchState: Equatable {
    case idle
    case launching
    case launched
    case unavailable(String)
    case failed(String)

    var message: String? {
        switch self {
        case .idle: return nil
        case .launching: return "Starting perch update…"
        case .launched: return "Updater launched. Perch may close while the update is installed."
        case .unavailable(let message), .failed(let message): return message
        }
    }
}

protocol UpdateProcessLaunching {
    func launch(executable: URL, arguments: [String]) throws
}

struct DetachedUpdateProcessLauncher: UpdateProcessLaunching {
    func launch(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Process does not terminate children when its object or parent app is
        // released. With every standard stream detached, the fixed CLI can
        // safely outlive normal app termination without pipe backpressure.
        try process.run()
    }
}

@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    static let installInstruction = "Install the Perch CLI, then run `perch update`."

    @Published private(set) var state: UpdateLaunchState = .idle
    private let executableURL: URL
    private let fileManager: FileManager
    private let launcher: UpdateProcessLaunching

    var canCheckForUpdates: Bool { state != .launching }
    var statusMessage: String? { state.message }

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        launcher: UpdateProcessLaunching = DetachedUpdateProcessLauncher()
    ) {
        executableURL = homeDirectory
            .appendingPathComponent(".local/bin/perch", isDirectory: false)
            .standardizedFileURL
        self.fileManager = fileManager
        self.launcher = launcher
    }

    func checkForUpdates() {
        guard state != .launching else { return }
        guard fileManager.fileExists(atPath: executableURL.path),
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            state = .unavailable(Self.installInstruction)
            return
        }
        state = .launching
        do {
            // This is deliberately not a shell invocation. Neither path nor
            // arguments can be influenced by settings, daemon events, or users.
            try launcher.launch(executable: executableURL, arguments: ["update"])
            state = .launched
        } catch {
            state = .failed(
                "Could not launch `perch update`: \(Self.bounded(error.localizedDescription))"
            )
        }
    }

    private static func bounded(_ value: String) -> String {
        String(value.prefix(300))
    }
}
