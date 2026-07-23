import Foundation
import XCTest
@testable import Perch

private final class MigrationKeychain: KeychainDataClient {
    var value: Data?
    func read(service: String, account: String) throws -> Data {
        guard let value else { throw SecureStoreError.missing }
        return value
    }
    func add(_ data: Data, service: String, account: String) throws {
        if value != nil { throw SecureStoreError.duplicate }
        value = data
    }
    func update(_ data: Data, service: String, account: String) throws { value = data }
    func delete(service: String, account: String) throws { value = nil }
}

final class AccountDataStoreTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporary)
    }

    func testPartitionsAreRestrictiveAndNeverShareFiles() throws {
        let store = AccountDataStore(rootURL: temporary.appendingPathComponent("Application Support"))
        let a = try store.conversationsURL(for: "user-a")
        let b = try store.conversationsURL(for: "user-b")
        try store.writeSecurely(Data("a".utf8), to: a)
        try store.writeSecurely(Data("b".utf8), to: b)

        XCTAssertNotEqual(a.deletingLastPathComponent(), b.deletingLastPathComponent())
        XCTAssertEqual(try permissions(a), 0o600)
        XCTAssertEqual(try permissions(a.deletingLastPathComponent()), 0o700)
    }

    func testMatchingMigrationIsIdempotentAndRemovesPlaintextOnlyAfterVerification() throws {
        let root = temporary.appendingPathComponent("Application Support")
        let legacy = temporary.appendingPathComponent(".danotch")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let session = AuthSession(
            accessToken: "secret", refreshToken: "refresh", expiresAt: 100,
            userId: "user-a", email: "a@example.com", fullName: "A"
        )
        try JSONEncoder().encode(session).write(to: legacy.appendingPathComponent("auth.json"))
        let conversations = #"{"conversations":[]}"#.data(using: .utf8)!
        try conversations.write(to: legacy.appendingPathComponent("conversations.json"))
        let keychain = MigrationKeychain()
        let secure = SecureSessionStore(keychain: keychain)
        try secure.save(session)
        let store = AccountDataStore(rootURL: root)

        try store.migrateLegacyData(
            activeSession: session,
            legacyDirectory: legacy,
            sessionStore: secure
        )
        try store.migrateLegacyData(
            activeSession: session,
            legacyDirectory: legacy,
            sessionStore: secure
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.conversationsURL(for: "user-a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("conversations.json").path))
    }

    func testCrossAccountLegacyDataIsNeverImportedOrDeleted() throws {
        let legacy = temporary.appendingPathComponent(".danotch")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacySession = AuthSession(
            accessToken: "secret-a", refreshToken: "refresh-a", expiresAt: nil,
            userId: "user-a", email: "a@example.com", fullName: "A"
        )
        let active = AuthSession(
            accessToken: "secret-b", refreshToken: "refresh-b", expiresAt: nil,
            userId: "user-b", email: "b@example.com", fullName: "B"
        )
        try JSONEncoder().encode(legacySession).write(to: legacy.appendingPathComponent("auth.json"))
        try Data(#"{"conversations":[]}"#.utf8).write(
            to: legacy.appendingPathComponent("conversations.json")
        )
        let secure = SecureSessionStore(keychain: MigrationKeychain())
        try secure.save(active)
        let store = AccountDataStore(rootURL: temporary.appendingPathComponent("support"))

        XCTAssertThrowsError(try store.migrateLegacyData(
            activeSession: active,
            legacyDirectory: legacy,
            sessionStore: secure
        )) { XCTAssertEqual($0 as? AccountDataError, .accountMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: (try store.conversationsURL(for: "user-b")).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("auth.json").path))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }
}
