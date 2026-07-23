import Foundation
import Security

enum SecureStoreError: Error, Equatable {
    case missing
    case duplicate
    case interactionDenied
    case invalidData
    case unexpectedStatus(Int32)
}

protocol KeychainDataClient {
    func read(service: String, account: String) throws -> Data
    func add(_ data: Data, service: String, account: String) throws
    func update(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

struct DataProtectionKeychainClient: KeychainDataClient {
    private func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read(service: String, account: String) throws -> Data {
        var value: CFTypeRef?
        var request = query(service: service, account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data else {
            throw mapKeychainStatus(status)
        }
        return data
    }

    func add(_ data: Data, service: String, account: String) throws {
        var request = query(service: service, account: account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw mapKeychainStatus(status) }
    }

    func update(_ data: Data, service: String, account: String) throws {
        let status = SecItemUpdate(
            query(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard status == errSecSuccess else { throw mapKeychainStatus(status) }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw mapKeychainStatus(status)
        }
    }
}

private func mapKeychainStatus(_ status: OSStatus) -> SecureStoreError {
    switch status {
    case errSecItemNotFound: return .missing
    case errSecDuplicateItem: return .duplicate
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .interactionDenied
    default: return .unexpectedStatus(status)
    }
}

final class SecureSessionStore {
    static let service = "engineering.super.Perch.session"
    static let account = "active-session"

    private let keychain: KeychainDataClient
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(keychain: KeychainDataClient = DataProtectionKeychainClient()) {
        self.keychain = keychain
    }

    func load() throws -> AuthSession {
        do {
            return try decoder.decode(
                AuthSession.self,
                from: keychain.read(service: Self.service, account: Self.account)
            )
        } catch let error as SecureStoreError {
            throw error
        } catch {
            throw SecureStoreError.invalidData
        }
    }

    func save(_ session: AuthSession) throws {
        let data = try encoder.encode(session)
        do {
            try keychain.add(data, service: Self.service, account: Self.account)
        } catch SecureStoreError.duplicate {
            try keychain.update(data, service: Self.service, account: Self.account)
        }
        guard try load() == session else { throw SecureStoreError.invalidData }
    }

    func rotate(from expectedUserID: String, to session: AuthSession) throws {
        let existing = try load()
        guard existing.userId == expectedUserID else { throw SecureStoreError.interactionDenied }
        try save(session)
    }

    func delete() throws {
        try keychain.delete(service: Self.service, account: Self.account)
    }
}
