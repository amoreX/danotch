import CryptoKit
import Foundation

public struct ExecutorArtifact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case kernelArchive, kernel, initImage, workloadImage }
    public let kind: Kind
    public let reference: String
    public let sha256: String
    public let bytes: Int?
    public let sourceSHA256: String?

    enum CodingKeys: String, CodingKey {
        case kind, reference, sha256, bytes
        case sourceSHA256 = "source_sha256"
    }
}

public struct ExecutorArtifactManifestPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let containerizationVersion: String
    public let containerizationCommit: String
    public let minimumOS: String
    public let architecture: String
    public let artifacts: [ExecutorArtifact]

    enum CodingKeys: String, CodingKey {
        case artifacts, architecture
        case schemaVersion = "schema_version"
        case containerizationVersion = "containerization_version"
        case containerizationCommit = "containerization_commit"
        case minimumOS = "minimum_os"
    }
}

public struct SignedExecutorArtifactManifest: Codable, Sendable {
    let algorithm: String
    let keyID: String
    let signedPayload: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case algorithm, signature
        case keyID = "key_id"
        case signedPayload = "signed_payload"
    }
}

public enum ArtifactVerificationError: Error, Equatable {
    case invalidManifest
    case unsupportedSigner
    case invalidSignature
    case invalidArtifact(String)
    case cacheMismatch(String)
}

public struct ExecutorArtifactManifestVerifier: Sendable {
    public enum VerificationMode: Sendable {
        case signedRelease
        /// Source-built ad-hoc applications have no release private key. This
        /// mode is only valid after the caller has strictly validated the
        /// enclosing app's sealed-resource signature. The seal binds the exact
        /// manifest bytes; this verifier still validates the pinned schema and
        /// every artifact digest.
        case enclosingBundleSeal
    }

    public static let releaseKeyID = "perch-executor-artifacts-2026-01"
    // Public verification material only. Resources/ExecutorArtifacts.json is
    // intentionally unsigned in source control. Protected U8 release CI signs
    // its canonical payload with the corresponding private key held outside
    // this repository; development tests create an isolated fixture key.
    public static let releasePublicKeyPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEw0GxpZZneZlYNcgeHV9sV62TZWoa
    xN0UvteMArMUnTaCkLvtKDi1Eiw9I3GFfiNaJ0li9d62h3hWD3TvXnWpEQ==
    -----END PUBLIC KEY-----
    """

    private let publicKeyPEM: String

    public init(publicKeyPEM: String = Self.releasePublicKeyPEM) {
        self.publicKeyPEM = publicKeyPEM
    }

    public func verify(
        data: Data,
        mode: VerificationMode = .signedRelease
    ) throws -> ExecutorArtifactManifestPayload {
        let envelope = try JSONDecoder().decode(SignedExecutorArtifactManifest.self, from: data)
        guard envelope.algorithm == "P256-SHA256-DER",
              envelope.keyID == Self.releaseKeyID,
              let payload = Data(base64Encoded: envelope.signedPayload) else {
            throw ArtifactVerificationError.invalidManifest
        }
        switch mode {
        case .signedRelease:
            guard let signatureData = Data(base64Encoded: envelope.signature) else {
                throw ArtifactVerificationError.invalidManifest
            }
            let key: P256.Signing.PublicKey
            do {
                key = try P256.Signing.PublicKey(pemRepresentation: publicKeyPEM)
            } catch {
                throw ArtifactVerificationError.unsupportedSigner
            }
            guard let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: signatureData
            ), key.isValidSignature(signature, for: payload) else {
                throw ArtifactVerificationError.invalidSignature
            }
        case .enclosingBundleSeal:
            // Never reinterpret a bad release signature as a source build.
            guard envelope.signature.isEmpty else {
                throw ArtifactVerificationError.invalidSignature
            }
        }
        let manifest = try JSONDecoder().decode(ExecutorArtifactManifestPayload.self, from: payload)
        try validate(manifest)
        return manifest
    }

    private func validate(_ manifest: ExecutorArtifactManifestPayload) throws {
        guard manifest.schemaVersion == 1,
              manifest.containerizationVersion == "0.33.3",
              manifest.containerizationCommit == "a2a1add6c7e1a1665e5397edc49d925c49090b3a",
              manifest.minimumOS == "26.0",
              manifest.architecture == "arm64",
              Set(manifest.artifacts.map(\.kind)) == Set([
                .kernelArchive, .kernel, .initImage, .workloadImage,
              ]) else {
            throw ArtifactVerificationError.invalidManifest
        }
        guard manifest.artifacts.count == 4 else {
            throw ArtifactVerificationError.invalidManifest
        }
        for artifact in manifest.artifacts {
            guard artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  artifact.reference.range(of: #"^(https://|ghcr\.io/)"#, options: .regularExpression) != nil,
                  artifact.bytes.map({ $0 > 0 }) ?? true,
                  artifact.sourceSHA256.map({
                      $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                  }) ?? true else {
                throw ArtifactVerificationError.invalidArtifact(artifact.reference)
            }
        }
    }
}

public protocol ExecutorArtifactFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct URLSessionArtifactFetcher: ExecutorArtifactFetching {
    public init() {}
    public func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw ArtifactVerificationError.invalidArtifact(url.absoluteString) }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

public actor ExecutorArtifactCache {
    private let root: URL
    private let fetcher: ExecutorArtifactFetching
    private let fileManager: FileManager

    public init(
        root: URL,
        fetcher: ExecutorArtifactFetching = URLSessionArtifactFetcher(),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fetcher = fetcher
        self.fileManager = fileManager
    }

    public func verifiedFile(for artifact: ExecutorArtifact, allowBootstrap: Bool) async throws -> URL {
        let target = root.appendingPathComponent(artifact.sha256, isDirectory: false)
        if fileManager.fileExists(atPath: target.path) {
            guard try digest(target) == artifact.sha256 else {
                try? fileManager.removeItem(at: target)
                throw ArtifactVerificationError.cacheMismatch(artifact.reference)
            }
            return target
        }
        guard allowBootstrap, let url = URL(string: artifact.reference), url.scheme == "https" else {
            throw ArtifactVerificationError.cacheMismatch(artifact.reference)
        }
        let data = try await fetcher.fetch(url)
        guard Self.digest(data) == artifact.sha256,
              artifact.bytes.map({ $0 == data.count }) ?? true else {
            throw ArtifactVerificationError.invalidArtifact(artifact.reference)
        }
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).download")
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: temporary.path)
        try fileManager.moveItem(at: temporary, to: target)
        guard try digest(target) == artifact.sha256 else {
            try? fileManager.removeItem(at: target)
            throw ArtifactVerificationError.cacheMismatch(artifact.reference)
        }
        return target
    }

    public func verifyExtracted(_ url: URL, artifact: ExecutorArtifact) throws {
        guard try digest(url) == artifact.sha256 else {
            throw ArtifactVerificationError.cacheMismatch(artifact.reference)
        }
    }

    private func digest(_ url: URL) throws -> String {
        Self.digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LocalActionOffer: Sendable {
    public let actionID: UUID
    public let registryVersion: String
    public let actionName: String
    public let normalizedParameters: ExecutorJSON
    public let parametersHash: String
    public let capabilities: ExecutionCapabilities
    public let imageDigest: String
    public let expiresAt: Date

    public init(
        actionID: UUID,
        registryVersion: String,
        actionName: String,
        normalizedParameters: ExecutorJSON,
        parametersHash: String,
        capabilities: ExecutionCapabilities,
        imageDigest: String,
        expiresAt: Date
    ) {
        self.actionID = actionID
        self.registryVersion = registryVersion
        self.actionName = actionName
        self.normalizedParameters = normalizedParameters
        self.parametersHash = parametersHash
        self.capabilities = capabilities
        self.imageDigest = imageDigest
        self.expiresAt = expiresAt
    }
}

public struct ExecutionGrant: Sendable {
    public let grantID: UUID
    public let actionID: UUID
    public let grantToken: String
    public let grantSignature: String
    public let actionHash: String
    public let parametersHash: String
    public let normalizedParameters: ExecutorJSON
    public let capabilities: ExecutionCapabilities
    public let imageDigest: String
    public let deviceID: UUID
    public let fence: Int
    public let expiresAt: Date
    public let transitionID: UUID

    public init(
        grantID: UUID,
        actionID: UUID,
        grantToken: String,
        grantSignature: String,
        actionHash: String,
        parametersHash: String,
        normalizedParameters: ExecutorJSON,
        capabilities: ExecutionCapabilities,
        imageDigest: String,
        deviceID: UUID,
        fence: Int,
        expiresAt: Date,
        transitionID: UUID
    ) {
        self.grantID = grantID
        self.actionID = actionID
        self.grantToken = grantToken
        self.grantSignature = grantSignature
        self.actionHash = actionHash
        self.parametersHash = parametersHash
        self.normalizedParameters = normalizedParameters
        self.capabilities = capabilities
        self.imageDigest = imageDigest
        self.deviceID = deviceID
        self.fence = fence
        self.expiresAt = expiresAt
        self.transitionID = transitionID
    }
}

public struct ExecutionGrantAuthorization: Sendable {
    public static let signedFields = [
        "grant_id", "action_id", "action_hash", "parameters_hash",
        "registry_version", "action_type", "normalized_parameters",
        "capabilities", "image_digest", "workspace_bookmark_id",
        "result_disclosure_policy", "session_id", "device_key_fingerprint",
        "device_id", "fence", "expires_at", "transition_id",
    ]

    public init() {}

    public func verify(payload: [String: Any]) throws {
        guard let token = payload["grant_token"] as? String,
              token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let signature = payload["grant_signature"] as? String,
              let signatureData = Data(base64URLEncoded: signature),
              signatureData.count == SHA256.byteCount else {
            throw LocalActionError.invalidBinding("grant authorization signature")
        }
        var signed: [String: Any] = [:]
        for field in Self.signedFields {
            guard let value = payload[field] else {
                throw LocalActionError.invalidBinding("missing signed grant field \(field)")
            }
            signed[field] = value
        }
        let canonical = try JSONSerialization.data(
            withJSONObject: signed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signatureData,
            authenticating: canonical,
            using: SymmetricKey(data: Data(token.utf8))
        ) else {
            throw LocalActionError.invalidBinding("grant authorization signature")
        }
    }
}

public struct ValidatedExecution: Sendable {
    public let offer: LocalActionOffer
    public let grant: ExecutionGrant
    public let action: RegisteredLocalAction
    public let workspace: WorkspaceScope
}

public struct ExecutionGrantValidator: Sendable {
    let registry: LocalActionRegistry
    let approvedImageDigest: String

    public init(approvedImageDigest: String) {
        self.registry = .shared
        self.approvedImageDigest = approvedImageDigest.lowercased()
    }

    init(registry: LocalActionRegistry, approvedImageDigest: String) {
        self.registry = registry
        self.approvedImageDigest = approvedImageDigest.lowercased()
    }

    public func validate(
        offer: LocalActionOffer,
        grant: ExecutionGrant,
        connectedDeviceID: UUID,
        currentFence: Int,
        workspace: WorkspaceScope,
        now: Date = Date()
    ) throws -> ValidatedExecution {
        guard grant.grantToken.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw LocalActionError.invalidBinding("grant authorization signature is malformed")
        }
        guard offer.actionID == grant.actionID else {
            throw LocalActionError.invalidBinding("action ID")
        }
        guard grant.deviceID == connectedDeviceID else {
            throw LocalActionError.invalidBinding("device ID")
        }
        guard grant.fence == currentFence, currentFence >= 0 else {
            throw LocalActionError.invalidBinding("connection fence")
        }
        guard offer.expiresAt > now, grant.expiresAt > now, grant.expiresAt <= offer.expiresAt else {
            throw LocalActionError.expired
        }
        guard grant.imageDigest.lowercased() == approvedImageDigest,
              offer.imageDigest.lowercased() == approvedImageDigest else {
            throw LocalActionError.invalidBinding("image digest")
        }
        guard offer.normalizedParameters == grant.normalizedParameters,
              offer.parametersHash == grant.parametersHash,
              offer.capabilities == grant.capabilities else {
            throw LocalActionError.invalidBinding("normalized parameters or capabilities")
        }
        guard registry.parametersHash(grant.normalizedParameters) == grant.parametersHash else {
            throw LocalActionError.invalidBinding("normalized parameters hash")
        }
        let expectedActionHash = registry.actionHash(
            registryVersion: offer.registryVersion,
            name: offer.actionName,
            parameters: grant.normalizedParameters
        )
        guard expectedActionHash == grant.actionHash else {
            throw LocalActionError.invalidBinding("action hash")
        }
        let action = try registry.resolve(
            registryVersion: offer.registryVersion,
            name: offer.actionName,
            parameters: grant.normalizedParameters,
            capabilities: grant.capabilities
        )
        if workspace.containsSensitiveFiles {
            guard grant.capabilities.sensitiveFileAccess else {
                throw LocalActionError.invalidBinding("sensitive file access")
            }
        }
        if workspace.containsSensitiveFiles && !grant.capabilities.sensitiveOutputDisclosure {
            // Reading was separately approved, but remote disclosure remains disabled.
            guard !grant.capabilities.resultUpload else {
                throw LocalActionError.invalidBinding("sensitive output disclosure")
            }
        }
        return ValidatedExecution(offer: offer, grant: grant, action: action, workspace: workspace)
    }
}

public enum ExecutorCapabilityState: Equatable, Sendable {
    case available
    case unsupportedOS
    case unsupportedArchitecture
    case artifactsUnavailable(String)
    case virtualizationUnavailable(String)

    public static var current: ExecutorCapabilityState {
        #if arch(arm64)
        if #available(macOS 26, *) { return .available }
        return .unsupportedOS
        #else
        return .unsupportedArchitecture
        #endif
    }
}

public protocol ContainerRuntime: Sendable {
    var capabilityState: ExecutorCapabilityState { get }
    func execute(_ request: ValidatedExecution) async throws -> ExecutionResult
    func cancel(actionID: UUID) async
    func cleanup(actionID: UUID) async
}

public struct UnavailableContainerRuntime: ContainerRuntime {
    public let capabilityState: ExecutorCapabilityState
    public init(state: ExecutorCapabilityState = .current) { capabilityState = state }
    public func execute(_ request: ValidatedExecution) async throws -> ExecutionResult {
        throw LocalActionError.unsupported
    }
    public func cancel(actionID: UUID) async {}
    public func cleanup(actionID: UUID) async {}
}

public protocol DeviceExecutionBackend: Sendable {
    var capabilityState: ExecutorCapabilityState { get }
    func execute(
        grantPayload: [String: Any],
        deviceID: String,
        userID: String
    ) async throws -> ExecutionResult
    func cancel(actionID: String) async
}

public struct DisabledDeviceExecutionBackend: DeviceExecutionBackend {
    public let capabilityState: ExecutorCapabilityState = .current
    public init() {}
    public func execute(
        grantPayload: [String: Any],
        deviceID: String,
        userID: String
    ) async throws -> ExecutionResult {
        throw LocalActionError.unsupported
    }
    public func cancel(actionID: String) async {}
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
