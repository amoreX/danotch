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

struct DraftCard {
    let type: String
    let title: String
    let preview: String
    let recipient: String?
}

struct ChatMessage: Identifiable {
    let id: String
    let role: String
    var content: String
    let toolName: String?
    var toolInput: String?
    var toolOutput: String?
    let draftCard: DraftCard?
    let timestamp: Date
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
    var isFromHistory: Bool = false

    var isActive: Bool {
        status == .running || status == .pending || status == .awaitingApproval
    }

    var needsApproval: Bool {
        status == .awaitingApproval
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

    var statusIcon: String {
        switch status {
        case .pending: return "circle.dashed"
        case .running: return "bolt.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case .awaitingApproval: return "exclamationmark.circle.fill"
        }
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
        case .claudeCode: return Color(hex: 0xD97757) // Claude orange
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
        case .toolUse: return Color(hex: 0xD97757)
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
    case stats
    case processList
    case settings
    case notifications

    static func == (lhs: NotchViewState, rhs: NotchViewState) -> Bool {
        switch (lhs, rhs) {
        case (.overview, .overview): return true
        case (.taskList, .taskList): return true
        case (.agentChat(let a), .agentChat(let b)): return a == b
        case (.stats, .stats): return true
        case (.processList, .processList): return true
        case (.settings, .settings): return true
        case (.notifications, .notifications): return true
        default: return false
        }
    }
}

// MARK: - Scheduled Tasks

struct ScheduledTask: Identifiable {
    let id: String
    let name: String
    let prompt: String
    let taskType: String
    let scheduleHuman: String
    var enabled: Bool
    let lastRunAt: String?
    let nextRunAt: String?
    let runCount: Int
    let lastStatus: String?
    let lastResultSummary: String?
    let notifyUser: Bool
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
