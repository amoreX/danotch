import Foundation
import SwiftUI
import Combine

class NotchViewModel: ObservableObject {
    @Published var tasks: [SubagentTask] = []
    @Published var currentTime: Date = Date()
    @Published var weather: WeatherInfo = WeatherInfo(temp: 72, condition: "Sunny", icon: "sun.max.fill")
    @Published var viewState: NotchViewState = .overview
    @Published var isExpanded = false
    @Published var shimmerStep: Int = 0
    @Published var shouldFocusChatInput = false
    @Published var isChatInputActive = false
    @Published var collapsedGroups: Set<String> = [] // agent group IDs that are collapsed
    var mouseInContent = false

    @Published var agentMonitor = AgentMonitor()
    private var clockTimer: Timer?
    private var shimmerTimer: Timer?
    private var agentMonitorCancellable: AnyCancellable?

    var delegatedCount: Int { tasks.filter { $0.status == .running || $0.status == .pending }.count }
    var approvalCount: Int { tasks.filter { $0.status == .awaitingApproval }.count }
    var finishedCount: Int { tasks.filter { $0.status == .completed }.count }
    var totalCount: Int { tasks.count }
    var hasActiveTasks: Bool { delegatedCount > 0 || approvalCount > 0 }

    var runningAgentCount: Int { agentMonitor.agents.filter { $0.status == .running }.count }
    var totalAgentCount: Int { agentMonitor.agents.count }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: currentTime)
    }

    var periodString: String {
        let f = DateFormatter()
        f.dateFormat = "a"
        return f.string(from: currentTime)
    }

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: currentTime)
    }

    var shortDateString: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: currentTime)
    }

    var shortTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: currentTime)
    }

    init() {
        startClock()
        startShimmerCycle()
        // Forward agent monitor changes to trigger view updates
        agentMonitorCancellable = agentMonitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func startClock() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.currentTime = Date()
            }
        }
    }

    func startShimmerCycle() {
        shimmerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                withAnimation(.easeInOut(duration: 0.4)) {
                    self?.shimmerStep += 1
                }
            }
        }
    }

    func activityText(for task: SubagentTask) -> String {
        guard !task.activitySteps.isEmpty else { return "Working..." }
        return task.activitySteps[shimmerStep % task.activitySteps.count]
    }

    func taskById(_ id: String) -> SubagentTask? {
        tasks.first { $0.id == id }
    }

    func resetView() {
        withAnimation(.snappy(duration: 0.25)) {
            viewState = .overview
        }
    }

    var isInTaskOrChat: Bool {
        switch viewState {
        case .taskList, .agentChat: return true
        default: return false
        }
    }

    var isStatsOrSettings: Bool {
        viewState == .stats || viewState == .settings
    }

    // MARK: - Event Processing

    func processEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "subagent_event": processSubagentEvent(json)
        case "task_summary": processBulkUpdate(json)
        default: break
        }
    }

    private func processSubagentEvent(_ json: [String: Any]) {
        guard let sessionId = json["session_id"] as? String,
              let eventType = json["event_type"] as? String else { return }
        let data = json["data"] as? [String: Any] ?? [:]
        switch eventType {
        case "status": upsertTask(from: data, sessionId: sessionId)
        case "progress": handleProgress(sessionId: sessionId, data: data)
        case "done": handleDone(sessionId: sessionId, data: data)
        default: break
        }
    }

    private func upsertTask(from data: [String: Any], sessionId: String) {
        let task = SubagentTask(
            id: sessionId,
            task: data["task"] as? String ?? "Unknown task",
            description: data["description"] as? String,
            status: TaskStatus(rawValue: data["status"] as? String ?? "pending") ?? .pending,
            toolCallsCount: data["tool_calls_count"] as? Int ?? 0,
            streamingText: "",
            createdAt: Date(),
            activitySteps: [],
            chatHistory: []
        )
        if let idx = tasks.firstIndex(where: { $0.id == sessionId }) {
            tasks[idx] = task
        } else {
            withAnimation(.snappy(duration: 0.3)) { tasks.append(task) }
        }
    }

    private func handleProgress(sessionId: String, data: [String: Any]) {
        guard let idx = tasks.firstIndex(where: { $0.id == sessionId }) else {
            let task = SubagentTask(
                id: sessionId, task: data["message"] as? String ?? "Task",
                status: .running, toolCallsCount: 0, streamingText: "",
                createdAt: Date(), activitySteps: [], chatHistory: []
            )
            withAnimation(.snappy(duration: 0.3)) { tasks.append(task) }
            return
        }
        let progressType = data["type"] as? String ?? ""
        withAnimation(.snappy(duration: 0.2)) {
            tasks[idx].status = .running
            switch progressType {
            case "token":
                if let text = data["text"] as? String { tasks[idx].streamingText += text }
            case "tool_start":
                tasks[idx].currentToolName = data["tool_name"] as? String
            case "tool_result":
                tasks[idx].toolCallsCount += 1
                tasks[idx].currentToolName = nil
            case "thinking_complete":
                if let text = data["text"] as? String { tasks[idx].streamingText = text }
            default: break
            }
        }
    }

    private func handleDone(sessionId: String, data: [String: Any]) {
        guard let idx = tasks.firstIndex(where: { $0.id == sessionId }) else { return }
        let statusStr = data["status"] as? String ?? "completed"
        withAnimation(.snappy(duration: 0.3)) {
            tasks[idx].status = TaskStatus(rawValue: statusStr) ?? .completed
            tasks[idx].completedAt = Date()
            tasks[idx].currentToolName = nil
            if let result = data["result"] as? String { tasks[idx].result = result }
            if let error = data["error"] as? String { tasks[idx].error = error }
        }
    }

    private func processBulkUpdate(_ json: [String: Any]) {
        guard let taskList = json["tasks"] as? [[String: Any]] else { return }
        var newTasks: [SubagentTask] = []
        for t in taskList {
            newTasks.append(SubagentTask(
                id: t["id"] as? String ?? UUID().uuidString,
                task: t["task"] as? String ?? "Unknown",
                description: t["description"] as? String,
                status: TaskStatus(rawValue: t["status"] as? String ?? "pending") ?? .pending,
                toolCallsCount: t["tool_calls_count"] as? Int ?? 0,
                currentToolName: t["current_tool"] as? String,
                streamingText: t["streaming_text"] as? String ?? "",
                result: t["result"] as? String,
                error: t["error"] as? String,
                createdAt: Date(),
                activitySteps: [],
                chatHistory: []
            ))
        }
        withAnimation(.snappy(duration: 0.3)) { tasks = newTasks }
    }

    // MARK: - Chat

    func sendChat(message: String) {
        let sessionId = UUID().uuidString

        // Optimistically create a task so it shows immediately
        let task = SubagentTask(
            id: sessionId,
            task: message,
            description: String(message.prefix(60)),
            status: .running,
            toolCallsCount: 0,
            streamingText: "",
            createdAt: Date(),
            activitySteps: ["Sending to Claude..."],
            chatHistory: [
                ChatMessage(
                    id: UUID().uuidString, role: "user", content: message,
                    toolName: nil, draftCard: nil, timestamp: Date()
                )
            ]
        )
        withAnimation(.snappy(duration: 0.3)) {
            tasks.insert(task, at: 0)
            viewState = .taskList
        }

        // POST to backend
        guard let url = URL(string: "http://localhost:3001/api/chat") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["message": message, "session_id": sessionId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, _, error in
            if let error = error {
                DispatchQueue.main.async {
                    guard let self = self,
                          let idx = self.tasks.firstIndex(where: { $0.id == sessionId }) else { return }
                    withAnimation(.snappy(duration: 0.3)) {
                        self.tasks[idx].status = .failed
                        self.tasks[idx].error = error.localizedDescription
                    }
                }
            }
            // Success is handled by WebSocket events updating the task
        }.resume()
    }
}
