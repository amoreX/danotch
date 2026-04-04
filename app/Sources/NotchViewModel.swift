import Foundation
import SwiftUI
import Combine

enum MusicSize: String, CaseIterable {
    case mini = "mini"
    case big = "big"

    var label: String {
        switch self {
        case .mini: return "MINI"
        case .big: return "BIG"
        }
    }
}

enum CalendarMode: String, CaseIterable {
    case off = "off"
    case mini = "mini"    // one-line horizontal strip
    case large = "large"  // full grid

    var label: String {
        switch self {
        case .off: return "OFF"
        case .mini: return "MINI"
        case .large: return "LARGE"
        }
    }
}

class NotchSettings: ObservableObject {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".danotch")
    private static let configFile = configDir.appendingPathComponent("settings.json")

    // Chat behavior
    @Published var openChatOnSend: Bool        { didSet { save() } }
    @Published var restoreLastView: Bool       { didSet { save() } }
    @Published var keepOpenInChat: Bool        { didSet { save() } }

    // Display
    @Published var calendarMode: CalendarMode  { didSet { save() } }
    @Published var showMusic: Bool             { didSet { save() } }
    @Published var musicSize: MusicSize       { didSet { save() } }
    @Published var showBattery: Bool           { didSet { save() } }
    @Published var showDotGrid: Bool           { didSet { save() } }

    // Agents
    @Published var showAgentLiveState: Bool    { didSet { save() } }
    @Published var compactAgentRows: Bool      { didSet { save() } }

    // Dot grid
    @Published var dotGridColor: String        { didSet { save() } }
    @Published var dotGridOpacity: Double      { didSet { save() } }

    var dotGridSwiftColor: Color {
        Color(hex: UInt32(dotGridColor.dropFirst(), radix: 16) ?? 0xFFFFFF)
    }

    // UI state (persisted across restarts)
    @Published var collapsedGroups: Set<String> { didSet { save() } }

    init() {
        // Set defaults first
        openChatOnSend = true
        restoreLastView = false
        keepOpenInChat = true
        calendarMode = .large
        showMusic = true
        musicSize = .mini
        showBattery = true
        showDotGrid = true
        showAgentLiveState = true
        compactAgentRows = false
        dotGridColor = "#FFFFFF"
        dotGridOpacity = 0.6
        collapsedGroups = []

        // Then load from file
        load()
    }

    private func save() {
        let data: [String: Any] = [
            "openChatOnSend": openChatOnSend,
            "keepOpenInChat": keepOpenInChat,
            "restoreLastView": restoreLastView,
            "calendarMode": calendarMode.rawValue,
            "showMusic": showMusic,
            "musicSize": musicSize.rawValue,
            "showBattery": showBattery,
            "showDotGrid": showDotGrid,
            "showAgentLiveState": showAgentLiveState,
            "compactAgentRows": compactAgentRows,
            "dotGridColor": dotGridColor,
            "dotGridOpacity": dotGridOpacity,
            "collapsedGroups": Array(collapsedGroups),
        ]
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: Self.configFile)
        } catch {
            // Silent fail
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let v = json["openChatOnSend"] as? Bool { openChatOnSend = v }
        if let v = json["keepOpenInChat"] as? Bool { keepOpenInChat = v }
        if let v = json["restoreLastView"] as? Bool { restoreLastView = v }
        if let v = json["calendarMode"] as? String { calendarMode = CalendarMode(rawValue: v) ?? .large }
        if let v = json["showMusic"] as? Bool { showMusic = v }
        if let v = json["musicSize"] as? String { musicSize = MusicSize(rawValue: v) ?? .mini }
        if let v = json["showBattery"] as? Bool { showBattery = v }
        if let v = json["showDotGrid"] as? Bool { showDotGrid = v }
        if let v = json["showAgentLiveState"] as? Bool { showAgentLiveState = v }
        if let v = json["compactAgentRows"] as? Bool { compactAgentRows = v }
        if let v = json["dotGridColor"] as? String { dotGridColor = v }
        if let v = json["dotGridOpacity"] as? Double { dotGridOpacity = v }
        if let v = json["collapsedGroups"] as? [String] { collapsedGroups = Set(v) }
    }
}

class NotchViewModel: ObservableObject {
    @Published var tasks: [SubagentTask] = []
    @Published var currentTime: Date = Date()
    @Published var viewState: NotchViewState = .overview
    @Published var isExpanded = false
    @Published var shimmerStep: Int = 0
    @Published var shouldFocusChatInput = false
    @Published var isChatInputActive = false
    var mouseInContent = false
    var lastViewBeforeCollapse: NotchViewState = .overview

    var authManager: AuthManager?

    @Published var settings = NotchSettings()
    @Published var agentMonitor = AgentMonitor()
    @Published var nowPlaying = NowPlayingMonitor()
    let statsMonitor = SystemStatsMonitor()
    private var clockTimer: Timer?
    private var shimmerTimer: Timer?
    private var agentMonitorCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []

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
        nowPlaying.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
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
        shimmerTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                withAnimation(.easeInOut(duration: 0.4)) {
                    self?.shimmerStep += 1
                }
            }
        }
    }

    func activityText(for task: SubagentTask) -> String {
        // Show streaming text snippet once response starts coming in
        if !task.streamingText.isEmpty {
            let snippet = task.streamingText
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let trimmed = snippet.count > 60 ? String(snippet.suffix(57)) + "..." : snippet
            return trimmed
        }
        guard !task.activitySteps.isEmpty else { return "Working..." }
        return task.activitySteps[shimmerStep % task.activitySteps.count]
    }

    func taskById(_ id: String) -> SubagentTask? {
        tasks.first { $0.id == id }
    }

    // MARK: - Thread History

    struct ThreadSummary: Identifiable {
        let id: String
        let title: String?
        let updatedAt: String
    }

    @Published var threadHistory: [ThreadSummary] = []
    @Published var isLoadingHistory = false

    func loadThreadHistory() {
        guard let auth = authManager else {
            print("[Danotch] loadThreadHistory: no auth manager")
            return
        }
        isLoadingHistory = true
        print("[Danotch] loadThreadHistory: fetching...")

        // Refresh token if needed, then fetch
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run { self.isLoadingHistory = false }
                print("[Danotch] loadThreadHistory: no token after refresh")
                return
            }
            await self.fetchThreadHistory(token: token)
        }
    }

    private func fetchThreadHistory(token: String) async {

        var request = URLRequest(url: URL(string: "http://localhost:3001/api/threads")!)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingHistory = false

                if let error {
                    print("[Danotch] loadThreadHistory error: \(error.localizedDescription)")
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data else {
                    print("[Danotch] loadThreadHistory: no data, status=\(statusCode)")
                    return
                }

                if statusCode != 200 {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("[Danotch] loadThreadHistory: status=\(statusCode) body=\(body)")
                    return
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let threads = json["threads"] as? [[String: Any]] else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    print("[Danotch] loadThreadHistory: parse failed, body=\(body)")
                    return
                }

                self.threadHistory = threads.compactMap { t in
                    guard let id = t["id"] as? String else { return nil }
                    return ThreadSummary(
                        id: id,
                        title: t["title"] as? String,
                        updatedAt: t["updated_at"] as? String ?? ""
                    )
                }
                print("[Danotch] loadThreadHistory: loaded \(self.threadHistory.count) threads")
            }
        }.resume()
    }

    func loadThread(_ threadId: String) {
        guard let token = authManager?.accessToken else { return }

        // If already loaded in tasks, just navigate
        if tasks.contains(where: { $0.threadId == threadId || $0.id == threadId }) {
            let taskId = tasks.first(where: { $0.threadId == threadId || $0.id == threadId })!.id
            withAnimation(DN.transition) { viewState = .agentChat(taskId) }
            return
        }

        var request = URLRequest(url: URL(string: "http://localhost:3001/api/threads/\(threadId)")!)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messages = json["messages"] as? [[String: Any]] else { return }

                let chatHistory: [ChatMessage] = messages.compactMap { m in
                    guard let id = m["id"] as? String,
                          let role = m["role"] as? String,
                          let content = m["content"] as? String else { return nil }

                    let metadata = m["metadata"] as? [String: Any]
                    let displayRole: String
                    if role == "assistant" {
                        // Check if this was a failed/partial message
                        let status = metadata?["status"] as? String
                        displayRole = status == "failed" ? "agent" : "agent"
                    } else {
                        displayRole = role
                    }

                    return ChatMessage(
                        id: id,
                        role: displayRole,
                        content: content,
                        toolName: nil,
                        draftCard: nil,
                        timestamp: Date()
                    )
                }

                guard !chatHistory.isEmpty else { return }

                // Find title from first user message
                let firstUserMsg = chatHistory.first(where: { $0.role == "user" })?.content ?? "Conversation"
                let taskId = UUID().uuidString

                let status: TaskStatus = {
                    if let lastAssistant = messages.last(where: { ($0["role"] as? String) == "assistant" }),
                       let metadata = lastAssistant["metadata"] as? [String: Any],
                       let s = metadata["status"] as? String, s == "failed" {
                        return .failed
                    }
                    return .completed
                }()

                let task = SubagentTask(
                    id: taskId,
                    task: firstUserMsg,
                    description: String(firstUserMsg.prefix(60)),
                    status: status,
                    toolCallsCount: 0,
                    streamingText: "",
                    createdAt: Date(),
                    activitySteps: [],
                    chatHistory: chatHistory,
                    threadId: threadId
                )

                withAnimation(.snappy(duration: 0.3)) {
                    self.tasks.insert(task, at: 0)
                    self.viewState = .agentChat(taskId)
                }
            }
        }.resume()
    }

    func resetView() {
        lastViewBeforeCollapse = viewState
        withAnimation(.snappy(duration: 0.25)) {
            viewState = .overview
        }
    }

    func restoreOrResetView() {
        if settings.restoreLastView {
            withAnimation(.snappy(duration: 0.25)) {
                viewState = lastViewBeforeCollapse
            }
        }
        // else stays at .overview (default on expand)
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
        if let idx = tasks.firstIndex(where: { $0.id == sessionId }) {
            // Update existing task — preserve chatHistory
            tasks[idx].status = TaskStatus(rawValue: data["status"] as? String ?? "running") ?? .running
            if let desc = data["description"] as? String { tasks[idx].description = desc }
            if let count = data["tool_calls_count"] as? Int { tasks[idx].toolCallsCount = count }
        } else {
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
            if let result = data["result"] as? String {
                tasks[idx].result = result
                // Add agent response to chat history
                tasks[idx].chatHistory.append(ChatMessage(
                    id: UUID().uuidString, role: "agent", content: result,
                    toolName: nil, draftCard: nil, timestamp: Date()
                ))
            }
            if let error = data["error"] as? String {
                tasks[idx].error = error
                tasks[idx].chatHistory.append(ChatMessage(
                    id: UUID().uuidString, role: "agent", content: "Error: \(error)",
                    toolName: nil, draftCard: nil, timestamp: Date()
                ))
            }
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

    // MARK: - Goofy Loading Phrases

    static let goofyLoadingPhrases: [String] = [
        "Waking up the brain...",
        "Consulting the oracle...",
        "Summoning neurons...",
        "Thinking really hard...",
        "Downloading wisdom...",
        "Asking the void...",
        "Bribing the AI...",
        "Spinning up hamsters...",
        "Loading vibes...",
        "Booting consciousness...",
        "Warming up synapses...",
        "Channeling big brain...",
        "Rummaging through thoughts...",
        "Poking the model...",
        "Juggling tokens...",
        "Herding electrons...",
        "Sacrificing compute...",
        "Dusting off knowledge...",
        "Entering the matrix...",
        "Calibrating sass levels...",
        "Brewing intelligence...",
        "Untangling concepts...",
        "Vibing with vectors...",
        "Consulting ancient scrolls...",
        "Performing dark math...",
        "Assembling words...",
        "Negotiating with GPUs...",
        "Crunching cosmic data...",
        "Tickling transformers...",
        "Manifesting answers...",
        "Asking nicely...",
        "Whispering to silicon...",
        "Charging the flux...",
        "Parsing the universe...",
        "Feeding the beast...",
        "Tuning the frequencies...",
        "Cooking up replies...",
        "Mining for insight...",
        "Shaking the magic 8-ball...",
        "Consulting my twin...",
        "Running on caffeine...",
        "Defragmenting thoughts...",
        "Invoking the algorithm...",
        "Stretching brain cells...",
        "Warming the oven...",
        "Rolling the dice...",
        "Polishing the answer...",
        "Stirring the pot...",
        "Reticulating splines...",
        "Compiling thoughts...",
        "Buffering brilliance...",
        "Querying the cosmos...",
        "Loading sarcasm module...",
        "Priming the pump...",
        "Aligning chakras...",
        "Booting neural nets...",
        "Decoding your vibe...",
        "Fetching smartness...",
        "Beaming up data...",
        "Consulting the elders...",
        "Generating coherence...",
        "Wrangling parameters...",
        "Synthesizing wisdom...",
        "Activating turbo mode...",
        "Meditating on it...",
        "Scanning the multiverse...",
        "Doing the math...",
        "Powering up lasers...",
        "Hacking the mainframe...",
        "Asking my mom...",
        "Overthinking this...",
        "Going full galaxy brain...",
        "Transmitting thoughts...",
        "Loading personality...",
        "Deploying charm...",
        "Crunching numbers fr...",
        "Entering hyperdrive...",
        "Sipping knowledge...",
        "Unlocking potential...",
    ]

    // MARK: - Chat

    func sendChat(message: String, sessionId: String? = nil) {
        let sid = sessionId ?? UUID().uuidString
        let isFollowUp = sessionId != nil

        if isFollowUp {
            // Follow-up: add user message to existing task
            if let idx = tasks.firstIndex(where: { $0.id == sid }) {
                withAnimation(.snappy(duration: 0.3)) {
                    tasks[idx].chatHistory.append(ChatMessage(
                        id: UUID().uuidString, role: "user", content: message,
                        toolName: nil, draftCard: nil, timestamp: Date()
                    ))
                    tasks[idx].status = .running
                    tasks[idx].streamingText = ""
                    tasks[idx].result = nil
                    tasks[idx].error = nil
                }
            }
        } else {
            // New task
            let task = SubagentTask(
                id: sid,
                task: message,
                description: String(message.prefix(60)),
                status: .running,
                toolCallsCount: 0,
                streamingText: "",
                createdAt: Date(),
                activitySteps: Self.goofyLoadingPhrases.shuffled(),
                chatHistory: [
                    ChatMessage(
                        id: UUID().uuidString, role: "user", content: message,
                        toolName: nil, draftCard: nil, timestamp: Date()
                    )
                ]
            )
            withAnimation(.snappy(duration: 0.3)) {
                tasks.insert(task, at: 0)
                if settings.openChatOnSend {
                    viewState = .agentChat(sid)
                }
                // else: stay on current page, task appears in background
            }
        }

        // POST to backend (refresh token first if needed)
        let auth = authManager
        let threadIdForRequest = tasks.first(where: { $0.id == sid })?.threadId
        Task {
            await auth?.ensureValidToken()
            guard let url = URL(string: "http://localhost:3001/api/chat") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = auth?.accessToken {
                request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            var body: [String: Any] = ["message": message, "session_id": sid]
            if let threadId = threadIdForRequest {
                body["thread_id"] = threadId
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self = self,
                      let idx = self.tasks.firstIndex(where: { $0.id == sid }) else { return }
                if let error = error {
                    withAnimation(.snappy(duration: 0.3)) {
                        self.tasks[idx].status = .failed
                        self.tasks[idx].error = error.localizedDescription
                    }
                    return
                }
                // Capture thread_id from response for follow-ups
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let threadId = json["thread_id"] as? String {
                    self.tasks[idx].threadId = threadId
                }
            }
            // Success is handled by WebSocket events updating the task
        }.resume()
        } // Task
    }
}
