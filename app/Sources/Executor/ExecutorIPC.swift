import CryptoKit
import Darwin
import Foundation

public enum ExecutorIPCError: Error, Equatable {
    case oversized
    case malformed
    case unsupportedMessage
    case unauthenticated
    case staleFence
    case replay
    case executorUnavailable
}

public struct ExecutorIPCRequest: Codable, Sendable {
    public static let version = 1
    public static let maximumBytes = 512 * 1_024
    public static let messageType = "execute_grant"

    public let version: Int
    public let type: String
    public let requestID: UUID
    public let sessionID: UUID
    public let deviceID: UUID
    public let fence: Int
    public let grantJSON: Data
    public let workspaceBookmark: Data
    public let devicePublicKeyPEM: String
    public let ipcSecret: Data
    public let signatureDER: Data

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, type
        case requestID = "request_id"
        case sessionID = "session_id"
        case deviceID = "device_id"
        case fence
        case grantJSON = "grant_json"
        case workspaceBookmark = "workspace_bookmark"
        case devicePublicKeyPEM = "device_public_key_pem"
        case ipcSecret = "ipc_secret"
        case signatureDER = "signature_der"
    }

    public init(
        requestID: UUID,
        sessionID: UUID,
        deviceID: UUID,
        fence: Int,
        grantJSON: Data,
        workspaceBookmark: Data,
        devicePublicKeyPEM: String,
        ipcSecret: Data,
        signatureDER: Data
    ) {
        version = Self.version
        type = Self.messageType
        self.requestID = requestID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.fence = fence
        self.grantJSON = grantJSON
        self.workspaceBookmark = workspaceBookmark
        self.devicePublicKeyPEM = devicePublicKeyPEM
        self.ipcSecret = ipcSecret
        self.signatureDER = signatureDER
    }

    public func signingData() throws -> Data {
        try Self.canonicalData([
            "version": version,
            "type": type,
            "request_id": requestID.uuidString.lowercased(),
            "session_id": sessionID.uuidString.lowercased(),
            "device_id": deviceID.uuidString.lowercased(),
            "fence": fence,
            "grant_json": grantJSON.base64EncodedString(),
            "workspace_bookmark": workspaceBookmark.base64EncodedString(),
            "device_public_key_pem": devicePublicKeyPEM,
            "ipc_secret": ipcSecret.base64EncodedString(),
        ])
    }

    public static func decode(_ data: Data) throws -> ExecutorIPCRequest {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw data.count > maximumBytes ? ExecutorIPCError.oversized : ExecutorIPCError.malformed
        }
        let request = try JSONDecoder().decode(Self.self, from: data)
        guard request.version == version, request.type == messageType else {
            throw ExecutorIPCError.unsupportedMessage
        }
        guard request.ipcSecret.count == 32,
              request.signatureDER.count >= 8,
              request.signatureDER.count <= 80,
              request.fence >= 0,
              request.grantJSON.count <= maximumBytes / 2,
              request.workspaceBookmark.count <= 128 * 1_024,
              request.devicePublicKeyPEM.utf8.count <= 1_000 else {
            throw ExecutorIPCError.malformed
        }
        return request
    }

    fileprivate static func canonicalData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

public struct ExecutorIPCResponse: Codable, Sendable {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public let version: Int
    public let type: String
    public let requestID: UUID
    public let resultJSON: Data
    public let authenticationTag: Data

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, type
        case requestID = "request_id"
        case resultJSON = "result_json"
        case authenticationTag = "authentication_tag"
    }

    public init(requestID: UUID, resultJSON: Data, ipcSecret: Data) throws {
        version = ExecutorIPCRequest.version
        type = "execution_result"
        self.requestID = requestID
        self.resultJSON = resultJSON
        authenticationTag = Data(HMAC<SHA256>.authenticationCode(
            for: try Self.authenticationData(requestID: requestID, resultJSON: resultJSON),
            using: SymmetricKey(data: ipcSecret)
        ))
    }

    public func verify(ipcSecret: Data, expectedRequestID: UUID) throws {
        guard version == ExecutorIPCRequest.version,
              type == "execution_result",
              requestID == expectedRequestID,
              authenticationTag.count == SHA256.byteCount,
              HMAC<SHA256>.isValidAuthenticationCode(
                authenticationTag,
                authenticating: try Self.authenticationData(
                    requestID: requestID,
                    resultJSON: resultJSON
                ),
                using: SymmetricKey(data: ipcSecret)
              ) else {
            throw ExecutorIPCError.unauthenticated
        }
    }

    public static func decode(_ data: Data) throws -> ExecutorIPCResponse {
        guard data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw data.count > maximumBytes ? ExecutorIPCError.oversized : ExecutorIPCError.malformed
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private static func authenticationData(requestID: UUID, resultJSON: Data) throws -> Data {
        try ExecutorIPCRequest.canonicalData([
            "request_id": requestID.uuidString.lowercased(),
            "result_json": resultJSON.base64EncodedString(),
        ])
    }
}

public struct ExecutorIPCAuthenticator: Sendable {
    public init() {}

    public func verify(_ request: ExecutorIPCRequest, now: Date = Date()) throws -> [String: Any] {
        let key: P256.Signing.PublicKey
        let signature: P256.Signing.ECDSASignature
        do {
            key = try P256.Signing.PublicKey(pemRepresentation: request.devicePublicKeyPEM)
            signature = try P256.Signing.ECDSASignature(derRepresentation: request.signatureDER)
        } catch {
            throw ExecutorIPCError.unauthenticated
        }
        guard key.isValidSignature(signature, for: try request.signingData()),
              let grant = try JSONSerialization.jsonObject(with: request.grantJSON) as? [String: Any],
              grant["device_id"] as? String == request.deviceID.uuidString.lowercased(),
              grant["session_id"] as? String == request.sessionID.uuidString.lowercased(),
              grant["fence"] as? Int == request.fence,
              let expiry = grant["expires_at"] as? String,
              ISO8601DateFormatter().date(from: expiry).map({ $0 > now }) == true,
              let expectedFingerprint = grant["device_key_fingerprint"] as? String,
              expectedFingerprint == Self.fingerprint(key) else {
            throw ExecutorIPCError.unauthenticated
        }
        return grant
    }

    private static func fingerprint(_ key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.derRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct ExecutorIPCReplayGuard: Sendable {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func claim(requestID: UUID, grantID: UUID) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let markerName = LocalActionRegistry.sha256(
            requestID.uuidString.lowercased() + ":" + grantID.uuidString.lowercased()
        )
        let marker = root.appendingPathComponent(markerName)
        let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ExecutorIPCError.replay }
            throw ExecutorIPCError.malformed
        }
        close(descriptor)
    }
}
