import CryptoKit
import Foundation
import XCTest
@testable import Perch

private final class IdentityKeychain: KeychainDataClient {
    var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data {
        guard let value = values[account] else { throw SecureStoreError.missing }
        return value
    }
    func add(_ data: Data, service: String, account: String) throws {
        guard values[account] == nil else { throw SecureStoreError.duplicate }
        values[account] = data
    }
    func update(_ data: Data, service: String, account: String) throws { values[account] = data }
    func delete(service: String, account: String) throws { values.removeValue(forKey: account) }
}

private struct FakeHardwareKey: HardwareDeviceSigningKey {
    let key: P256.Signing.PrivateKey
    let encryptedRepresentation: Data
    var publicX963Representation: Data { key.publicKey.x963Representation }
    func signatureDER(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

private final class FakeHardwareFactory: HardwareDeviceKeyFactory {
    var unavailable = false
    private(set) var lastCreatedRepresentation: Data?
    private var restored: [Data: FakeHardwareKey] = [:]

    func create() throws -> HardwareDeviceSigningKey {
        if unavailable { throw DeviceIdentityError.secureEnclaveUnavailable }
        let representation = Data(UUID().uuidString.utf8)
        let key = FakeHardwareKey(
            key: P256.Signing.PrivateKey(),
            encryptedRepresentation: representation
        )
        lastCreatedRepresentation = representation
        restored[representation] = key
        return key
    }

    func restore(encryptedRepresentation: Data) throws -> HardwareDeviceSigningKey {
        if unavailable { throw DeviceIdentityError.secureEnclaveUnavailable }
        guard let key = restored[encryptedRepresentation] else {
            throw DeviceIdentityError.invalidStoredKey
        }
        return key
    }
}

final class DeviceIdentityStoreTests: XCTestCase {
    func testSelectsStableHardwareP256IdentityAndStoresOnlyEncryptedRepresentation() throws {
        let keychain = IdentityKeychain()
        let factory = FakeHardwareFactory()
        let store = DeviceIdentityStore(keychain: keychain, factory: factory)
        let first = try store.identity(for: "user-a", createIfMissing: true)
        let second = try store.identity(for: "user-a", createIfMissing: false)

        XCTAssertEqual(try first.publicKey, try second.publicKey)
        XCTAssertEqual(try first.publicKey.algorithm, "P-256")
        XCTAssertEqual(try first.publicKey.format, "spki-pem")
        XCTAssertFalse(try first.sign(Data("challenge".utf8)).isEmpty)
        XCTAssertEqual(keychain.values["user-a"], factory.lastCreatedRepresentation)
    }

    func testSecureEnclaveFailureDoesNotCreateExportableFallback() throws {
        let keychain = IdentityKeychain()
        let factory = FakeHardwareFactory()
        factory.unavailable = true
        let store = DeviceIdentityStore(keychain: keychain, factory: factory)

        XCTAssertThrowsError(try store.identity(for: "user-a", createIfMissing: true)) {
            XCTAssertEqual($0 as? DeviceIdentityError, .secureEnclaveUnavailable)
        }
        XCTAssertTrue(keychain.values.isEmpty)
    }

    func testDeleteRequiresFreshHardwareIdentityOnNextEnrollment() throws {
        let keychain = IdentityKeychain()
        let store = DeviceIdentityStore(keychain: keychain, factory: FakeHardwareFactory())
        _ = try store.identity(for: "user-a", createIfMissing: true)
        try store.deleteIdentity(for: "user-a")
        XCTAssertThrowsError(try store.identity(for: "user-a", createIfMissing: false)) {
            XCTAssertEqual($0 as? SecureStoreError, .missing)
        }
    }
}
