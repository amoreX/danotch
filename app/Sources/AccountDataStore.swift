import Foundation

enum AccountDataError: Error, Equatable {
    case invalidUserID
    case accountMismatch
    case verificationFailed
}

struct DeviceAccountState: Codable, Equatable {
    var deviceID: String?
    var deviceKeyAlgorithm: String?
    var cursor: Int
    var processedTransitionIDs: [String]
    var pendingResults: [PendingDeviceResult]

    static let empty = DeviceAccountState(
        deviceID: nil,
        deviceKeyAlgorithm: nil,
        cursor: 0,
        processedTransitionIDs: [],
        pendingResults: []
    )

    init(
        deviceID: String?,
        deviceKeyAlgorithm: String? = nil,
        cursor: Int,
        processedTransitionIDs: [String],
        pendingResults: [PendingDeviceResult] = []
    ) {
        self.deviceID = deviceID
        self.deviceKeyAlgorithm = deviceKeyAlgorithm
        self.cursor = cursor
        self.processedTransitionIDs = processedTransitionIDs
        self.pendingResults = pendingResults
    }

    enum CodingKeys: String, CodingKey {
        case deviceID, deviceKeyAlgorithm, cursor, processedTransitionIDs, pendingResults
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try values.decodeIfPresent(String.self, forKey: .deviceID)
        deviceKeyAlgorithm = try values.decodeIfPresent(String.self, forKey: .deviceKeyAlgorithm)
        cursor = try values.decodeIfPresent(Int.self, forKey: .cursor) ?? 0
        processedTransitionIDs = try values.decodeIfPresent(
            [String].self,
            forKey: .processedTransitionIDs
        ) ?? []
        pendingResults = try values.decodeIfPresent(
            [PendingDeviceResult].self,
            forKey: .pendingResults
        ) ?? []
    }
}

struct PendingDeviceResult: Codable, Equatable {
    let resultID: String
    let actionID: String
    let grantID: String
    let status: String
    let resultJSON: Data
}

final class AccountDataStore {
    private let fileManager: FileManager
    let rootURL: URL

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Perch", isDirectory: true)
    }

    func accountDirectory(for userID: String) throws -> URL {
        guard isValidUserID(userID) else { throw AccountDataError.invalidUserID }
        let directory = rootURL
            .appendingPathComponent("Accounts", isDirectory: true)
            .appendingPathComponent(userID, isDirectory: true)
        try secureDirectory(directory)
        return directory
    }

    func conversationsURL(for userID: String) throws -> URL {
        try accountDirectory(for: userID).appendingPathComponent("conversations.json")
    }

    func stateURL(for userID: String) throws -> URL {
        try accountDirectory(for: userID).appendingPathComponent("device-state.json")
    }

    func loadDeviceState(for userID: String) throws -> DeviceAccountState {
        let url = try stateURL(for: userID)
        guard fileManager.fileExists(atPath: url.path) else { return .empty }
        return try JSONDecoder().decode(DeviceAccountState.self, from: Data(contentsOf: url))
    }

    func saveDeviceState(_ state: DeviceAccountState, for userID: String) throws {
        try writeSecurely(JSONEncoder().encode(state), to: stateURL(for: userID))
        guard try loadDeviceState(for: userID) == state else {
            throw AccountDataError.verificationFailed
        }
    }

    /// Imports legacy plaintext only after a freshly authenticated session
    /// proves ownership. Destination verification precedes deletion, making
    /// interruption safe and retries idempotent.
    func migrateLegacyData(
        activeSession: AuthSession,
        legacyDirectory: URL? = nil,
        sessionStore: SecureSessionStore
    ) throws {
        let legacy = legacyDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".danotch", isDirectory: true)
        let authURL = legacy.appendingPathComponent("auth.json")
        guard fileManager.fileExists(atPath: authURL.path) else { return }
        let legacySession = try JSONDecoder().decode(AuthSession.self, from: Data(contentsOf: authURL))
        guard legacySession.userId == activeSession.userId else {
            throw AccountDataError.accountMismatch
        }
        guard try sessionStore.load().userId == activeSession.userId else {
            throw AccountDataError.accountMismatch
        }

        let legacyConversations = legacy.appendingPathComponent("conversations.json")
        let destination = try conversationsURL(for: activeSession.userId)
        if fileManager.fileExists(atPath: legacyConversations.path) {
            let sourceData = try Data(contentsOf: legacyConversations)
            if fileManager.fileExists(atPath: destination.path) {
                let merged = try mergeConversationFiles(
                    destination: Data(contentsOf: destination),
                    legacy: sourceData
                )
                try writeSecurely(merged, to: destination)
            } else {
                try writeSecurely(sourceData, to: destination)
            }
            guard fileManager.fileExists(atPath: destination.path),
                  !(try Data(contentsOf: destination)).isEmpty else {
                throw AccountDataError.verificationFailed
            }
            try fileManager.removeItem(at: legacyConversations)
        }

        // Tokens are already verified in the Data Protection Keychain.
        try fileManager.removeItem(at: authURL)
    }

    func writeSecurely(_ data: Data, to url: URL) throws {
        try secureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func secureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func isValidUserID(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 128
            && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    private func mergeConversationFiles(destination: Data, legacy: Data) throws -> Data {
        struct GenericStore: Codable {
            var conversations: [LocalConversationRecord]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(GenericStore.self, from: destination)
        let old = try decoder.decode(GenericStore.self, from: legacy)
        var byID = Dictionary(uniqueKeysWithValues: current.conversations.map { ($0.id, $0) })
        for record in old.conversations where byID[record.id] == nil {
            byID[record.id] = record
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(GenericStore(
            conversations: byID.values.sorted { $0.updatedAt > $1.updatedAt }
        ))
    }
}
