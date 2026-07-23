import Foundation

@available(macOS 26.0, *)
struct ExecutorRequestDecoder {
    func validatedExecution(
        request: ExecutorIPCRequest,
        grant: [String: Any],
        manifest: ExecutorArtifactManifestPayload,
        now: Date = Date()
    ) throws -> ValidatedExecution {
        try ExecutionGrantAuthorization().verify(payload: grant)
        let required = Set([
            "grant_id", "action_id", "sequence", "grant_token", "grant_signature",
            "action_hash", "parameters_hash", "registry_version", "action_type",
            "normalized_parameters", "capabilities", "image_digest",
            "workspace_bookmark_id", "result_disclosure_policy", "session_id",
            "device_key_fingerprint", "device_id", "fence", "expires_at",
            "transition_id",
        ])
        guard Set(grant.keys) == required,
              let grantID = (grant["grant_id"] as? String).flatMap(UUID.init(uuidString:)),
              let actionID = (grant["action_id"] as? String).flatMap(UUID.init(uuidString:)),
              let transitionID = (grant["transition_id"] as? String).flatMap(UUID.init(uuidString:)),
              let registryVersion = grant["registry_version"] as? String,
              let actionType = grant["action_type"] as? String,
              let parametersValue = grant["normalized_parameters"],
              let capabilitiesValue = grant["capabilities"],
              let parametersHash = grant["parameters_hash"] as? String,
              let actionHash = grant["action_hash"] as? String,
              let token = grant["grant_token"] as? String,
              let signature = grant["grant_signature"] as? String,
              let imageDigest = grant["image_digest"] as? String,
              let fence = grant["fence"] as? Int,
              let expiryValue = grant["expires_at"] as? String,
              let expiry = ISO8601DateFormatter().date(from: expiryValue),
              let disclosure = grant["result_disclosure_policy"] as? [String: Any],
              Set(disclosure.keys) == Set(["sensitive_output", "upload"]),
              let sensitiveDisclosure = disclosure["sensitive_output"] as? Bool,
              let resultUpload = disclosure["upload"] as? Bool else {
            throw LocalActionError.invalidBinding("executor grant schema")
        }
        let parameters = try ExecutorJSON(any: parametersValue)
        let capabilities = try ExecutionCapabilities(json: ExecutorJSON(any: capabilitiesValue))
        guard capabilities.egressDestinations.isEmpty,
              capabilities.sensitiveOutputDisclosure == sensitiveDisclosure,
              capabilities.resultUpload == resultUpload else {
            throw LocalActionError.invalidBinding("network or result disclosure policy")
        }
        guard let workload = manifest.artifacts.first(where: { $0.kind == .workloadImage }) else {
            throw ArtifactVerificationError.invalidManifest
        }
        let approvedImage = "sha256:" + workload.sha256
        let offer = LocalActionOffer(
            actionID: actionID,
            registryVersion: registryVersion,
            actionName: actionType,
            normalizedParameters: parameters,
            parametersHash: parametersHash,
            capabilities: capabilities,
            imageDigest: imageDigest,
            expiresAt: expiry
        )
        let executionGrant = ExecutionGrant(
            grantID: grantID,
            actionID: actionID,
            grantToken: token,
            grantSignature: signature,
            actionHash: actionHash,
            parametersHash: parametersHash,
            normalizedParameters: parameters,
            capabilities: capabilities,
            imageDigest: imageDigest,
            deviceID: request.deviceID,
            fence: fence,
            expiresAt: expiry,
            transitionID: transitionID
        )
        let workspace = try WorkspaceAccess().open(
            bookmark: WorkspaceBookmark(data: request.workspaceBookmark),
            mode: capabilities.workspaceMode,
            quota: .init(
                maximumFiles: min(capabilities.limits.processCount * 1_000, 100_000),
                maximumBytes: capabilities.limits.diskBytes
            )
        )
        do {
            return try ExecutionGrantValidator(
                approvedImageDigest: approvedImage
            ).validate(
                offer: offer,
                grant: executionGrant,
                connectedDeviceID: request.deviceID,
                currentFence: request.fence,
                workspace: workspace,
                now: now
            )
        } catch {
            workspace.close()
            throw error
        }
    }
}
