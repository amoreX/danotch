import Foundation

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
    let content: String
    let toolName: String?
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

struct WeatherInfo {
    var temp: Int
    var condition: String
    var icon: String
}

enum NotchViewState: Equatable {
    case overview
    case taskList
    case agentChat(String)

    static func == (lhs: NotchViewState, rhs: NotchViewState) -> Bool {
        switch (lhs, rhs) {
        case (.overview, .overview): return true
        case (.taskList, .taskList): return true
        case (.agentChat(let a), .agentChat(let b)): return a == b
        default: return false
        }
    }
}
