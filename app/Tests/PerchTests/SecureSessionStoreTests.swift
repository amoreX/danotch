import Foundation
import XCTest
@testable import Perch

private final class FakeKeychain: KeychainDataClient {
    var values: [String: Data] = [:]
    var denied = false

    func read(service: String, account: String) throws -> Data {
        if denied { throw SecureStoreError.interactionDenied }
        guard let value = values["\(service):\(account)"] else { throw SecureStoreError.missing }
        return value
    }

    func add(_ data: Data, service: String, account: String) throws {
        if denied { throw SecureStoreError.interactionDenied }
        let key = "\(service):\(account)"
        guard values[key] == nil else { throw SecureStoreError.duplicate }
        values[key] = data
    }

    func update(_ data: Data, service: String, account: String) throws {
        if denied { throw SecureStoreError.interactionDenied }
        let key = "\(service):\(account)"
        guard values[key] != nil else { throw SecureStoreError.missing }
        values[key] = data
    }

    func delete(service: String, account: String) throws {
        if denied { throw SecureStoreError.interactionDenied }
        values.removeValue(forKey: "\(service):\(account)")
    }
}

final class SecureSessionStoreTests: XCTestCase {
    private let first = AuthSession(
        accessToken: "access-a",
        refreshToken: "refresh-a",
        expiresAt: 100,
        userId: "user-a",
        email: "a@example.com",
        fullName: "A"
    )

    func testSaveHandlesDuplicateByRotatingAndVerifying() throws {
        let keychain = FakeKeychain()
        let store = SecureSessionStore(keychain: keychain)
        try store.save(first)
        var rotated = first
        rotated.accessToken = "access-b"
        rotated.refreshToken = "refresh-b"

        try store.rotate(from: first.userId, to: rotated)

        XCTAssertEqual(try store.load(), rotated)
    }

    func testMissingDeniedAndDeleteAreRecoverableStates() throws {
        let keychain = FakeKeychain()
        let store = SecureSessionStore(keychain: keychain)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SecureStoreError, .missing) }
        try store.save(first)
        keychain.denied = true
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? SecureStoreError, .interactionDenied)
        }
        keychain.denied = false
        try store.delete()
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? SecureStoreError, .missing) }
    }

    func testRotationCannotReplaceAnotherAccount() throws {
        let store = SecureSessionStore(keychain: FakeKeychain())
        try store.save(first)
        var other = first
        other.userId = "user-b"
        XCTAssertThrowsError(try store.rotate(from: "user-b", to: other)) {
            XCTAssertEqual($0 as? SecureStoreError, .interactionDenied)
        }
    }
}
