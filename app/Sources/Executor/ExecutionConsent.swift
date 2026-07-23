import Foundation

public struct ExecutionConsentDisclosure: Equatable, Sendable {
    let actionID: UUID
    let actionName: String
    let command: [String]
    let workspacePath: String
    let workspaceMode: ExecutionCapabilities.WorkspaceMode
    let egressDestinations: [String]
    let mayReadSensitiveFiles: Bool
    let sensitiveOutputMayLeaveDevice: Bool
    let resultWillBeUploaded: Bool
    let expiresAt: Date

    public var summary: String {
        let commandText = command.map(Self.shellQuote).joined(separator: " ")
        let network = egressDestinations.isEmpty
            ? "No network access"
            : "Network: \(egressDestinations.joined(separator: ", "))"
        let write = workspaceMode == .readOnly ? "read-only" : "read/write"
        let upload = resultWillBeUploaded ? "Result leaves this Mac" : "Result remains on this Mac"
        let sensitive = mayReadSensitiveFiles
            ? (sensitiveOutputMayLeaveDevice
                ? "Sensitive output may be disclosed"
                : "Sensitive output is redacted before disclosure")
            : "No sensitive-file access approved"
        return [
            "\(actionName): \(commandText)",
            "Mount \(workspacePath) (\(write))",
            network,
            sensitive,
            upload,
        ].joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public struct ExecutionApproval: Equatable, Sendable {
    public let approvalID: UUID
    public let actionID: UUID
    public let actionHash: String
    public let parametersHash: String
    public let capabilities: ExecutionCapabilities
    public let workspaceBookmarkHash: String
    public let approvedAt: Date
    public let expiresAt: Date
    public let highRiskShell: Bool

    public init(
        approvalID: UUID,
        actionID: UUID,
        actionHash: String,
        parametersHash: String,
        capabilities: ExecutionCapabilities,
        workspaceBookmarkHash: String,
        approvedAt: Date,
        expiresAt: Date,
        highRiskShell: Bool
    ) {
        self.approvalID = approvalID
        self.actionID = actionID
        self.actionHash = actionHash
        self.parametersHash = parametersHash
        self.capabilities = capabilities
        self.workspaceBookmarkHash = workspaceBookmarkHash
        self.approvedAt = approvedAt
        self.expiresAt = expiresAt
        self.highRiskShell = highRiskShell
    }
}

enum ConsentRequirement: Equatable, Sendable {
    case approvalRequired(ExecutionConsentDisclosure)
    case approved(ExecutionApproval)
}

public actor ExecutionConsentStore {
    public init() {}
    private var approvals: [UUID: ExecutionApproval] = [:]
    private var consumed: Set<UUID> = []

    public func record(_ approval: ExecutionApproval) throws {
        guard approval.expiresAt > approval.approvedAt else {
            throw LocalActionError.invalidBinding("approval expiry is invalid")
        }
        approvals[approval.actionID] = approval
    }

    public func consume(
        actionID: UUID,
        actionHash: String,
        parametersHash: String,
        capabilities: ExecutionCapabilities,
        workspaceBookmarkHash: String,
        highRiskShell: Bool,
        now: Date = Date()
    ) throws -> ExecutionApproval {
        guard !consumed.contains(actionID),
              let approval = approvals[actionID] else {
            throw LocalActionError.invalidBinding("a fresh single-use approval is required")
        }
        guard approval.expiresAt > now else {
            approvals.removeValue(forKey: actionID)
            throw LocalActionError.expired
        }
        guard approval.actionHash == actionHash,
              approval.parametersHash == parametersHash,
              approval.capabilities == capabilities,
              approval.workspaceBookmarkHash == workspaceBookmarkHash,
              approval.highRiskShell == highRiskShell else {
            throw LocalActionError.invalidBinding("approval does not match the exact action parameters and capabilities")
        }
        approvals.removeValue(forKey: actionID)
        consumed.insert(actionID)
        return approval
    }

    public func revoke(actionID: UUID) {
        approvals.removeValue(forKey: actionID)
    }
}

struct ConsentPolicy: Sendable {
    func requiresFreshApproval(
        previous: ExecutionApproval?,
        actionID: UUID,
        actionHash: String,
        parametersHash: String,
        capabilities: ExecutionCapabilities,
        workspaceBookmarkHash: String,
        highRiskShell: Bool
    ) -> Bool {
        guard let previous,
              previous.actionID == actionID,
              previous.actionHash == actionHash,
              previous.parametersHash == parametersHash,
              previous.capabilities == capabilities,
              previous.workspaceBookmarkHash == workspaceBookmarkHash,
              previous.highRiskShell == highRiskShell else {
            return true
        }
        // Approval is always single-use. Write, egress, sensitive disclosure,
        // result upload, and arbitrary shell therefore can never inherit consent.
        return true
    }
}
