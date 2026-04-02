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
    var mouseInContent = false

    private var clockTimer: Timer?
    private var shimmerTimer: Timer?

    var delegatedCount: Int { tasks.filter { $0.status == .running || $0.status == .pending }.count }
    var approvalCount: Int { tasks.filter { $0.status == .awaitingApproval }.count }
    var finishedCount: Int { tasks.filter { $0.status == .completed }.count }
    var totalCount: Int { tasks.count }
    var hasActiveTasks: Bool { delegatedCount > 0 || approvalCount > 0 }

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
        loadMockData()
        startClock()
        startShimmerCycle()
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

    // MARK: - Mock Data

    func loadMockData() {
        let now = Date()
        tasks = [
            SubagentTask(
                id: "mock-1",
                task: "Search Gmail for flight booking confirmation and extract travel details",
                description: "Search flight emails",
                status: .running,
                toolCallsCount: 2,
                currentToolName: "gmail_search",
                streamingText: "Searching for flight confirmation emails...",
                createdAt: now.addingTimeInterval(-30),
                activitySteps: [
                    "gmail_search → scanning inbox",
                    "gmail_read_email → reading confirmation",
                    "Extracting flight details...",
                    "Parsing booking reference...",
                ],
                chatHistory: [
                    ChatMessage(id: "m1-1", role: "agent", content: "I'll search your Gmail for flight booking confirmations.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-28)),
                    ChatMessage(id: "m1-2", role: "tool", content: "Found 3 emails matching 'flight confirmation'", toolName: "gmail_search", draftCard: nil, timestamp: now.addingTimeInterval(-25)),
                    ChatMessage(id: "m1-3", role: "tool", content: "Reading email from United Airlines...", toolName: "gmail_read_email", draftCard: nil, timestamp: now.addingTimeInterval(-20)),
                    ChatMessage(id: "m1-4", role: "agent", content: "Found your United Airlines booking — flight UA 247 from SFO to JFK on March 28th at 8:15 AM. Confirmation code is XKCD42, seat 14A (window), departing from Terminal 3, Gate B22. Still looking for the return flight details.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-15)),
                ]
            ),
            SubagentTask(
                id: "mock-4",
                task: "Draft a reply to the product team's design review thread",
                description: "Draft design review reply",
                status: .running,
                toolCallsCount: 1,
                currentToolName: "gmail_search",
                streamingText: "Reading the design review thread...",
                createdAt: now.addingTimeInterval(-15),
                activitySteps: [
                    "gmail_search → finding thread",
                    "gmail_read_email → reading context",
                    "Composing reply draft...",
                    "gmail_create_draft → saving",
                ],
                chatHistory: [
                    ChatMessage(id: "m4-1", role: "agent", content: "Looking for the design review thread in your inbox.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-14)),
                    ChatMessage(id: "m4-2", role: "tool", content: "Found thread: 'Q2 Design Review — feedback needed'", toolName: "gmail_search", draftCard: nil, timestamp: now.addingTimeInterval(-12)),
                    ChatMessage(id: "m4-3", role: "agent", content: "Reading through the thread — 4 replies so far. Sarah raised concerns about the timeline, and Mike suggested splitting the project into phases. I'll draft a reply addressing both points.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-8)),
                ]
            ),
            SubagentTask(
                id: "mock-5",
                task: "Send a standup update to the engineering Slack channel",
                description: "Send Slack update",
                status: .awaitingApproval,
                toolCallsCount: 2,
                streamingText: "",
                createdAt: now.addingTimeInterval(-60),
                activitySteps: ["Waiting for approval..."],
                draftCard: DraftCard(
                    type: "slack_message",
                    title: "Standup update",
                    preview: "Hey team! Here's my update for today:\n- Finished the notch app prototype\n- PR #287 ready for review\n- Blocked on design feedback for the settings page",
                    recipient: "#engineering"
                ),
                chatHistory: [
                    ChatMessage(id: "m5-1", role: "agent", content: "I'll compose a standup update for the engineering channel.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-58)),
                    ChatMessage(id: "m5-2", role: "tool", content: "Fetched recent activity from Linear and GitHub", toolName: "linear_list_issues", draftCard: nil, timestamp: now.addingTimeInterval(-55)),
                    ChatMessage(id: "m5-3", role: "tool", content: "Read calendar for today's meetings", toolName: "calendar_list_events", draftCard: nil, timestamp: now.addingTimeInterval(-50)),
                    ChatMessage(id: "m5-4", role: "agent", content: "I've pulled together your standup update from today's Linear activity, GitHub PRs, and calendar. Here's a draft for #engineering — take a look and approve when ready:", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-45)),
                    ChatMessage(id: "m5-5", role: "draft", content: "", toolName: nil, draftCard: DraftCard(
                        type: "slack_message",
                        title: "Standup update",
                        preview: "Hey team! Here's my update for today:\n- Finished the notch app prototype\n- PR #287 ready for review\n- Blocked on design feedback for the settings page",
                        recipient: "#engineering"
                    ), timestamp: now.addingTimeInterval(-44)),
                ]
            ),
            SubagentTask(
                id: "mock-6",
                task: "Reply to Sarah's email about the Q2 roadmap planning meeting",
                description: "Reply to roadmap email",
                status: .awaitingApproval,
                toolCallsCount: 3,
                streamingText: "",
                createdAt: now.addingTimeInterval(-90),
                activitySteps: ["Waiting for approval..."],
                draftCard: DraftCard(
                    type: "gmail_draft",
                    title: "Re: Q2 Roadmap Planning",
                    preview: "Hi Sarah,\n\nThanks for setting this up! I'll be there. A few items I'd like to add to the agenda:\n1. Danotch integration timeline\n2. API rate limiting strategy\n3. Mobile app prioritization",
                    recipient: "sarah@company.com"
                ),
                chatHistory: [
                    ChatMessage(id: "m6-1", role: "agent", content: "Looking for Sarah's email about Q2 roadmap planning.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-88)),
                    ChatMessage(id: "m6-2", role: "tool", content: "Found email: 'Q2 Roadmap Planning — Thursday 3pm'", toolName: "gmail_search", draftCard: nil, timestamp: now.addingTimeInterval(-85)),
                    ChatMessage(id: "m6-3", role: "tool", content: "Read full thread (3 messages)", toolName: "gmail_read_email", draftCard: nil, timestamp: now.addingTimeInterval(-82)),
                    ChatMessage(id: "m6-4", role: "tool", content: "Checked calendar — no conflicts Thursday 3pm", toolName: "calendar_list_events", draftCard: nil, timestamp: now.addingTimeInterval(-78)),
                    ChatMessage(id: "m6-5", role: "agent", content: "No conflicts on your calendar for Thursday 3pm. I've drafted a reply confirming you'll attend and suggesting three agenda items based on your recent work. Review the draft below:", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-75)),
                    ChatMessage(id: "m6-6", role: "draft", content: "", toolName: nil, draftCard: DraftCard(
                        type: "gmail_draft",
                        title: "Re: Q2 Roadmap Planning",
                        preview: "Hi Sarah,\n\nThanks for setting this up! I'll be there. A few items I'd like to add to the agenda:\n1. Danotch integration timeline\n2. API rate limiting strategy\n3. Mobile app prioritization",
                        recipient: "sarah@company.com"
                    ), timestamp: now.addingTimeInterval(-74)),
                ]
            ),
            SubagentTask(
                id: "mock-3",
                task: "Update Linear ticket GH-142 status to In Review and add comment",
                description: "Update Linear ticket",
                status: .completed,
                toolCallsCount: 2,
                streamingText: "",
                result: "Updated GH-142 to 'In Review'. Added comment with PR link.",
                createdAt: now.addingTimeInterval(-180),
                completedAt: now.addingTimeInterval(-150),
                activitySteps: [],
                chatHistory: [
                    ChatMessage(id: "m3-1", role: "agent", content: "Updating Linear ticket GH-142.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-178)),
                    ChatMessage(id: "m3-2", role: "tool", content: "Updated status to 'In Review'", toolName: "linear_update_issue", draftCard: nil, timestamp: now.addingTimeInterval(-170)),
                    ChatMessage(id: "m3-3", role: "tool", content: "Added comment: 'PR #287 ready for review'", toolName: "linear_add_comment", draftCard: nil, timestamp: now.addingTimeInterval(-165)),
                    ChatMessage(id: "m3-4", role: "agent", content: "All done! I've moved GH-142 to 'In Review' and added a comment linking PR #287. The ticket now shows the latest status and the reviewer team has been notified.", toolName: nil, draftCard: nil, timestamp: now.addingTimeInterval(-160)),
                ]
            ),
        ]
    }
}
