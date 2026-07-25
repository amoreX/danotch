import Foundation
import SwiftUI

enum TaskStatus: String, Codable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case awaitingApproval = "awaiting_approval"
}

struct DraftCard: Codable {
    let type: String
    let title: String
    let preview: String
    let recipient: String?
}

enum LocalConsentConfirmation: String, Codable, CaseIterable, Hashable {
    case shell
    case write
    case sensitiveRead
    case sensitiveDisclosure
    case resultUpload
}

enum LocalConsentCardState: String, Codable {
    case pending
    case approving
    case approved
    case rejected
    case unavailable
    case failed
}

struct LocalExecutionConsentCard: Codable, Equatable {
    let actionID: String
    let registryVersion: String
    let actionType: String
    let actionHash: String
    let parametersHash: String
    let normalizedParametersJSON: Data
    let capabilitiesJSON: Data
    let workspaceBookmarkID: String
    let command: [String]
    let workspaceMode: String
    let egressDestinations: [String]
    let sensitiveFileAccess: Bool
    let sensitiveDisclosure: Bool
    let resultUpload: Bool
    let expiresAt: Date
    var expiresAtValue: String? = nil
    var selectedWorkspacePath: String?
    var confirmations: Set<LocalConsentConfirmation>
    var state: LocalConsentCardState
    var error: String?

    var requiredConfirmations: Set<LocalConsentConfirmation> {
        var required: Set<LocalConsentConfirmation> = []
        if actionType == "shell.execute" { required.insert(.shell) }
        if workspaceMode == "read_write" { required.insert(.write) }
        if sensitiveFileAccess { required.insert(.sensitiveRead) }
        if sensitiveDisclosure { required.insert(.sensitiveDisclosure) }
        if resultUpload { required.insert(.resultUpload) }
        return required
    }

    var canApprove: Bool {
        state == .pending
            && selectedWorkspacePath != nil
            && egressDestinations.isEmpty
            && confirmations.isSuperset(of: requiredConfirmations)
            && expiresAt > Date()
    }
}

enum LocalConsentCardEvent {
    case selectedWorkspace(String)
    case toggled(LocalConsentConfirmation)
    case approve
    case approved
    case reject
    case failed(String)
}

struct LocalConsentCardReducer {
    func reduce(
        _ card: LocalExecutionConsentCard,
        event: LocalConsentCardEvent
    ) -> LocalExecutionConsentCard {
        var next = card
        switch event {
        case .selectedWorkspace(let path):
            guard card.state == .pending else { return card }
            next.selectedWorkspacePath = path
        case .toggled(let confirmation):
            guard card.state == .pending,
                  card.requiredConfirmations.contains(confirmation) else { return card }
            if next.confirmations.contains(confirmation) {
                next.confirmations.remove(confirmation)
            } else {
                next.confirmations.insert(confirmation)
            }
        case .approve:
            guard card.canApprove else { return card }
            next.state = .approving
        case .approved:
            guard card.state == .approving else { return card }
            next.state = .approved
        case .reject:
            guard card.state == .pending || card.state == .approving else { return card }
            next.state = .rejected
        case .failed(let error):
            next.state = .failed
            next.error = error
        }
        return next
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: String
    let role: String
    var content: String
    let toolName: String?
    var toolInput: String?
    var toolOutput: String?
    let draftCard: DraftCard?
    var localExecutionCard: LocalExecutionConsentCard?
    let timestamp: Date

    init(
        id: String,
        role: String,
        content: String,
        toolName: String? = nil,
        toolInput: String? = nil,
        toolOutput: String? = nil,
        draftCard: DraftCard? = nil,
        localExecutionCard: LocalExecutionConsentCard? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolOutput = toolOutput
        self.draftCard = draftCard
        self.localExecutionCard = localExecutionCard
        self.timestamp = timestamp
    }
}

struct SubagentTask: Identifiable {
    let id: String
    var task: String
    var description: String?
    var status: TaskStatus
    var toolCallsCount: Int
    var currentToolName: String?
    var streamingText: String
    var result: String?
    var error: String?
    var createdAt: Date
    var completedAt: Date?
    var activitySteps: [String]
    var draftCard: DraftCard?
    var chatHistory: [ChatMessage]
    var threadId: String?
    var provider: String?
    var modelId: String?
    var isFromHistory: Bool = false

    var isActive: Bool {
        status == .running || status == .pending || status == .awaitingApproval
    }

    var durationSeconds: Double? {
        let end = completedAt ?? Date()
        return end.timeIntervalSince(createdAt)
    }

    var durationString: String {
        guard let seconds = durationSeconds else { return "-" }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }

}

// MARK: - Agent Monitoring

enum AgentType: String, CaseIterable {
    case claudeCode = "Claude Code"
    case cursor = "Cursor"
    case codex = "Codex"
    case windsurf = "Windsurf"

    var icon: String {
        switch self {
        case .claudeCode: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .codex: return "cpu"
        case .windsurf: return "wind"
        }
    }

    var brandColor: Color {
        switch self {
        case .claudeCode: return DN.claudeOrange
        case .cursor: return Color(hex: 0x00B4D8) // Cursor blue
        case .codex: return Color(hex: 0x10A37F) // OpenAI green
        case .windsurf: return Color(hex: 0x00C896) // Windsurf teal
        }
    }
}

enum AgentStatus: String {
    case running
    case idle

    var label: String {
        switch self {
        case .running: return "RUNNING"
        case .idle: return "IDLE"
        }
    }

    var color: Color {
        switch self {
        case .running: return DN.warning
        case .idle: return DN.textDisabled
        }
    }
}

enum AgentLiveState: Equatable {
    case idle
    case thinking
    case toolUse(String) // tool name
    case responding
    case waitingForUser

    var label: String {
        switch self {
        case .idle: return "IDLE"
        case .thinking: return "THINKING"
        case .toolUse(let tool): return toolDisplayName(tool)
        case .responding: return "RESPONDING"
        case .waitingForUser: return "WAITING"
        }
    }

    var color: Color {
        switch self {
        case .idle: return DN.textDisabled
        case .thinking: return DN.warning
        case .toolUse: return DN.claudeOrange
        case .responding: return DN.success
        case .waitingForUser: return DN.textSecondary
        }
    }

    var icon: String {
        switch self {
        case .idle: return "circle"
        case .thinking: return "brain"
        case .toolUse: return "hammer"
        case .responding: return "text.cursor"
        case .waitingForUser: return "person"
        }
    }

    private func toolDisplayName(_ name: String) -> String {
        switch name {
        case "Bash": return "RUNNING COMMAND"
        case "Read": return "READING FILE"
        case "Write": return "WRITING FILE"
        case "Edit": return "EDITING FILE"
        case "Grep": return "SEARCHING"
        case "Glob": return "FINDING FILES"
        case "Agent": return "RUNNING AGENT"
        case "WebSearch": return "WEB SEARCH"
        case "WebFetch": return "FETCHING URL"
        default: return name.uppercased()
        }
    }
}

struct DetectedAgent: Identifiable {
    let id: String // unique key: type + pid
    let type: AgentType
    let pid: Int32
    let status: AgentStatus
    let cpu: Double
    let memMB: Double
    let elapsed: String // e.g. "10:23"
    let workingDirectory: String? // cwd if detectable
    let sessionInfo: String? // e.g. session id or project name
    let appPath: String? // path to the app bundle for activation
    let lastPrompt: String? // last user message from conversation
    let lastActivityTime: Date? // timestamp of last user message in conversation
    let liveState: AgentLiveState // current activity
    let liveDetail: String? // extra context: tool command, file path, response snippet

    var displayName: String {
        if let session = sessionInfo, !session.isEmpty {
            return session
        }
        return type.rawValue
    }

    var projectName: String? {
        guard let cwd = workingDirectory else { return nil }
        return cwd.components(separatedBy: "/").last
    }
}

struct AgentGroup: Identifiable {
    let id: String
    let type: AgentType
    let agents: [DetectedAgent]

    var runningCount: Int { agents.filter { $0.status == .running }.count }
    var totalCpu: Double { agents.reduce(0) { $0 + $1.cpu } }
    var totalMem: Double { agents.reduce(0) { $0 + $1.memMB } }
}

enum NotchViewState: Equatable {
    case overview
    case taskList
    case agentChat(String)
    case agents
    case stats
    case processList
    case settings
    case notifications

    static func == (lhs: NotchViewState, rhs: NotchViewState) -> Bool {
        switch (lhs, rhs) {
        case (.overview, .overview): return true
        case (.taskList, .taskList): return true
        case (.agentChat(let a), .agentChat(let b)): return a == b
        case (.agents, .agents): return true
        case (.stats, .stats): return true
        case (.processList, .processList): return true
        case (.settings, .settings): return true
        case (.notifications, .notifications): return true
        default: return false
        }
    }

    /// Stable key for SwiftUI `.id()` so a view-state change triggers a clean cross-fade
    /// (insert/remove instead of in-place mutation).
    var transitionKey: String {
        switch self {
        case .overview: return "overview"
        case .taskList: return "taskList"
        case .agentChat(let id): return "agentChat-\(id)"
        case .agents: return "agents"
        case .stats: return "stats"
        case .processList: return "processList"
        case .settings: return "settings"
        case .notifications: return "notifications"
        }
    }
}

// MARK: - Scheduled Tasks

struct ScheduledTask: Identifiable {
    let id: String
    var name: String
    var prompt: String
    let taskType: String
    var scheduleHuman: String
    var cron: String?
    var intervalMs: Int?
    var enabled: Bool
    let lastRunAt: String?
    let nextRunAt: String?
    let runCount: Int
    let lastStatus: String?
    let lastResultSummary: String?
    var notifyUser: Bool
    var provider: String
    var modelId: String
}

struct ScheduledTaskDraft: Equatable {
    var name = ""
    var prompt = ""
    var cron = "0 9 * * *"
    var notifyUser = true
    var provider = "anthropic"
    var modelId = ProviderConfig.defaultModels["anthropic"] ?? ""
}

// MARK: - Connection Requests

enum ConnectionRequestStatus: String {
    case pending
    case connecting
    case approved
    case denied
}

struct PendingConnectionRequest {
    let requestId: String
    let sessionId: String
    let appType: String
    let displayName: String
    let reason: String
    var status: ConnectionRequestStatus
}

// MARK: - Provider Config (BYOK)

struct ProviderConfig: Identifiable {
    let id: String
    let provider: String
    var modelId: String
    var isActive: Bool
    var verifiedAt: String?
    var baseURL: String? = nil

    var displayName: String {
        switch provider {
        case "anthropic": return "Anthropic"
        case "openai": return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "deepseek": return "DeepSeek"
        case "custom": return "OpenAI Compatible"
        default: return provider.capitalized
        }
    }

    var icon: String {
        switch provider {
        case "anthropic": return "brain"
        case "openai": return "sparkles"
        case "openrouter": return "arrow.triangle.branch"
        case "deepseek": return "wave.3.right"
        case "custom": return "network"
        default: return "cpu"
        }
    }

    var isVerified: Bool { verifiedAt != nil }

    static let defaultModels: [String: String] = [
        "anthropic": "claude-sonnet-4-6",
        "openai": "gpt-5",
        "openrouter": "anthropic/claude-sonnet-4-6",
        "deepseek": "deepseek-chat",
        "custom": "",
    ]

    /// Fallback choices only. The chat selector fetches live provider models when possible.
    static let availableModels: [String: [(id: String, label: String)]] = [
        "anthropic": [
            ("claude-fable-5",                  "Fable 5"),
            ("claude-opus-4-8",                 "Opus 4.8"),
            ("claude-sonnet-4-6",               "Sonnet 4.6"),
            ("claude-haiku-4-5-20251001",       "Haiku 4.5"),
            ("claude-opus-4-7",                 "Opus 4.7"),
            ("claude-opus-4-6",                 "Opus 4.6"),
            ("claude-sonnet-4-5-20250929",      "Sonnet 4.5"),
        ],
        "openai": [
            ("gpt-5",      "GPT-5"),
            ("gpt-5-mini", "GPT-5 mini"),
            ("gpt-4o",     "GPT-4o"),
        ],
        "openrouter": [
            ("anthropic/claude-sonnet-4-6", "Sonnet 4.6"),
            ("anthropic/claude-opus-4-8",   "Opus 4.8"),
            ("anthropic/claude-haiku-4-5",  "Haiku 4.5"),
            ("openai/gpt-5",                "GPT-5"),
        ],
        "deepseek": [
            ("deepseek-chat", "DeepSeek Chat"),
            ("deepseek-reasoner", "DeepSeek Reasoner"),
        ],
        "custom": [],
    ]
}

struct ComposioIntegrationMetadata: Identifiable, Equatable {
    let appType: String
    let displayName: String
    var authConfigID: String?

    var id: String { appType }
}

struct ComposioConfigState: Equatable {
    var configured: Bool
    var connectedApps: [String]
    var localUserID: String? = nil
    var integrations: [ComposioIntegrationMetadata] = []

    static func parse(_ json: [String: Any]) -> ComposioConfigState {
        let integrations = (json["integrations"] as? [[String: Any]] ?? []).compactMap {
            value -> ComposioIntegrationMetadata? in
            guard let appType = value["app_type"] as? String,
                  let displayName = value["display_name"] as? String else { return nil }
            return ComposioIntegrationMetadata(
                appType: appType,
                displayName: displayName,
                authConfigID: value["auth_config_id"] as? String
            )
        }
        return ComposioConfigState(
            configured: json["configured"] as? Bool ?? false,
            connectedApps: json["connected_apps"] as? [String] ?? [],
            localUserID: json["local_user_id"] as? String,
            integrations: integrations
        )
    }
}

struct ProviderModelOption: Identifiable, Equatable {
    let id: String
    let name: String
    let provider: String
    let contextLength: Int?

    var displayName: String {
        name.isEmpty ? id : name
    }
}

struct NotificationItem: Identifiable {
    let id: String
    let title: String
    let body: String?
    let source: String
    let sourceId: String?
    var read: Bool
    let createdAt: String
}
