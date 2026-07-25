import Foundation

enum AccountDataError: Error, Equatable {
    case invalidUserID
    case verificationFailed
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

    func installationDirectory(for installationID: String) throws -> URL {
        guard isValidUserID(installationID) else { throw AccountDataError.invalidUserID }
        let directory = rootURL
            .appendingPathComponent("Installations", isDirectory: true)
            .appendingPathComponent(installationID.lowercased(), isDirectory: true)
        try secureDirectory(directory)
        return directory
    }

    func localConversationsURL(for installationID: String) throws -> URL {
        try installationDirectory(for: installationID)
            .appendingPathComponent("conversations.json")
    }

    /// Imports the pre-daemon conversation file into the installation
    /// partition. The legacy file is intentionally retained: merging by
    /// conversation id makes retries idempotent and avoids destructive
    /// migration before the daemon host owns backup/recovery.
    func importLegacyConversations(
        installationID: String,
        legacyDirectory: URL? = nil
    ) throws {
        let legacy = legacyDirectory ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".danotch", isDirectory: true)
        let source = legacy.appendingPathComponent("conversations.json")
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = try localConversationsURL(for: installationID)
        let sourceData = try Data(contentsOf: source)
        let merged: Data
        if fileManager.fileExists(atPath: destination.path) {
            merged = try mergeConversationFiles(
                destination: Data(contentsOf: destination),
                legacy: sourceData
            )
        } else {
            // Decode and re-encode to reject malformed legacy files and apply
            // the current schema before considering the import successful.
            merged = try mergeConversationFiles(
                destination: emptyConversationFile(),
                legacy: sourceData
            )
        }
        try writeSecurely(merged, to: destination)
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

    private func emptyConversationFile() throws -> Data {
        struct GenericStore: Codable {
            var conversations: [LocalConversationRecord]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(GenericStore(conversations: []))
    }
}
