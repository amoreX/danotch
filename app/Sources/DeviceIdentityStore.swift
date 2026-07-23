import CryptoKit
import Foundation

struct DevicePublicKey: Equatable {
    let algorithm: String
    let format: String
    let value: String
}

enum DeviceIdentityError: Error, Equatable {
    case secureEnclaveUnavailable
    case invalidStoredKey
}

protocol DeviceSigningIdentity {
    var publicKey: DevicePublicKey { get throws }
    func sign(_ message: Data) throws -> Data
    func delete() throws
}

protocol DeviceIdentityProviding {
    func identity(for userID: String, createIfMissing: Bool) throws -> DeviceSigningIdentity
    func deleteIdentity(for userID: String) throws
}

protocol HardwareDeviceSigningKey {
    var encryptedRepresentation: Data { get }
    var publicX963Representation: Data { get }
    func signatureDER(for message: Data) throws -> Data
}

protocol HardwareDeviceKeyFactory {
    func create() throws -> HardwareDeviceSigningKey
    func restore(encryptedRepresentation: Data) throws -> HardwareDeviceSigningKey
}

struct SecureEnclaveDeviceKeyFactory: HardwareDeviceKeyFactory {
    func create() throws -> HardwareDeviceSigningKey {
        guard SecureEnclave.isAvailable else {
            throw DeviceIdentityError.secureEnclaveUnavailable
        }
        do {
            return SecureEnclaveDeviceSigningKey(
                key: try SecureEnclave.P256.Signing.PrivateKey()
            )
        } catch {
            throw DeviceIdentityError.secureEnclaveUnavailable
        }
    }

    func restore(encryptedRepresentation: Data) throws -> HardwareDeviceSigningKey {
        guard SecureEnclave.isAvailable else {
            throw DeviceIdentityError.secureEnclaveUnavailable
        }
        do {
            return SecureEnclaveDeviceSigningKey(
                key: try SecureEnclave.P256.Signing.PrivateKey(
                    dataRepresentation: encryptedRepresentation
                )
            )
        } catch {
            throw DeviceIdentityError.invalidStoredKey
        }
    }
}

private struct SecureEnclaveDeviceSigningKey: HardwareDeviceSigningKey {
    let key: SecureEnclave.P256.Signing.PrivateKey
    var encryptedRepresentation: Data { key.dataRepresentation }
    var publicX963Representation: Data { key.publicKey.x963Representation }

    func signatureDER(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

/// Stores only Secure Enclave's encrypted key reference. The private scalar
/// never leaves the enclave and cannot be reconstructed from Keychain data.
final class DeviceIdentityStore: DeviceIdentityProviding {
    fileprivate static let service = "engineering.super.Perch.device-identity.p256"
    private let keychain: KeychainDataClient
    private let factory: HardwareDeviceKeyFactory

    init(
        keychain: KeychainDataClient = DataProtectionKeychainClient(),
        factory: HardwareDeviceKeyFactory = SecureEnclaveDeviceKeyFactory()
    ) {
        self.keychain = keychain
        self.factory = factory
    }

    func identity(for userID: String, createIfMissing: Bool) throws -> DeviceSigningIdentity {
        do {
            let encrypted = try keychain.read(service: Self.service, account: userID)
            return identity(
                try factory.restore(encryptedRepresentation: encrypted),
                userID: userID
            )
        } catch SecureStoreError.missing {
            guard createIfMissing else { throw SecureStoreError.missing }
        } catch let error as DeviceIdentityError {
            throw error
        } catch {
            throw DeviceIdentityError.invalidStoredKey
        }

        let key = try factory.create()
        do {
            try keychain.add(
                key.encryptedRepresentation,
                service: Self.service,
                account: userID
            )
        } catch SecureStoreError.duplicate {
            let encrypted = try keychain.read(service: Self.service, account: userID)
            return identity(
                try factory.restore(encryptedRepresentation: encrypted),
                userID: userID
            )
        }
        return identity(key, userID: userID)
    }

    func deleteIdentity(for userID: String) throws {
        try keychain.delete(service: Self.service, account: userID)
    }

    private func identity(
        _ key: HardwareDeviceSigningKey,
        userID: String
    ) -> DeviceSigningIdentity {
        HardwareBackedDeviceIdentity(
            key: key,
            userID: userID,
            keychain: keychain
        )
    }
}

private final class HardwareBackedDeviceIdentity: DeviceSigningIdentity {
    let key: HardwareDeviceSigningKey
    let userID: String
    let keychain: KeychainDataClient

    init(
        key: HardwareDeviceSigningKey,
        userID: String,
        keychain: KeychainDataClient
    ) {
        self.key = key
        self.userID = userID
        self.keychain = keychain
    }

    var publicKey: DevicePublicKey {
        get throws {
            let point = key.publicX963Representation
            guard point.count == 65, point.first == 0x04 else {
                throw DeviceIdentityError.invalidStoredKey
            }
            // RFC 5480 SubjectPublicKeyInfo for id-ecPublicKey + prime256v1.
            let prefix = Data([
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
                0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
                0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
                0x42, 0x00,
            ])
            let der = prefix + point
            let body = der.base64EncodedString(
                options: [.lineLength64Characters, .endLineWithLineFeed]
            )
            return DevicePublicKey(
                algorithm: "P-256",
                format: "spki-pem",
                value: "-----BEGIN PUBLIC KEY-----\n\(body)\n-----END PUBLIC KEY-----\n"
            )
        }
    }

    func sign(_ message: Data) throws -> Data {
        try key.signatureDER(for: message)
    }

    func delete() throws {
        try keychain.delete(service: DeviceIdentityStore.service, account: userID)
    }
}

extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
