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

enum PinnedWidget: String, CaseIterable, Codable {
    case calendar = "calendar"
    case music = "music"
    case ram = "ram"
    case disk = "disk"
    case network = "network"
    case uptime = "uptime"
    case processes = "processes"
    case scheduledTasks = "scheduledTasks"

    var label: String {
        switch self {
        case .calendar:       return "Calendar"
        case .music:          return "Music Player"
        case .ram:            return "RAM Usage"
        case .disk:           return "Disk Usage"
        case .network:        return "Network"
        case .uptime:         return "Uptime"
        case .processes:      return "Processes"
        case .scheduledTasks: return "Scheduled Tasks"
        }
    }

    var icon: String {
        switch self {
        case .calendar:       return "calendar"
        case .music:          return "music.note"
        case .ram:            return "memorychip"
        case .disk:           return "internaldrive"
        case .network:        return "network"
        case .uptime:         return "clock"
        case .processes:      return "list.number"
        case .scheduledTasks: return "clock.arrow.2.circlepath"
        }
    }

    var gridHeight: CGFloat {
        104
    }

}

class NotchSettings: ObservableObject {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".danotch")
    private static let configFile = configDir.appendingPathComponent("settings.json")

    // Chat behavior
    @Published var openChatOnSend: Bool        { didSet { save() } }
    @Published var restoreLastView: Bool       { didSet { save() } }
    @Published var keepOpenInChat: Bool        { didSet { save() } }
    @Published var selectedDefaultModel: String { didSet { save() } }

    // Display — pinned widgets
    @Published var pinnedWidgets: [PinnedWidget] { didSet { save() } }
    @Published var showBattery: Bool           { didSet { save() } }

    // Agents
    @Published var showAgentLiveState: Bool    { didSet { save() } }
    @Published var compactAgentRows: Bool      { didSet { save() } }

    // Widget sizing: rawValue → "half" | "full"
    @Published var widgetSizes: [String: String] = [:] { didSet { save() } }

    func widgetIsFullWidth(_ widget: PinnedWidget) -> Bool {
        widgetSizes[widget.rawValue] == "full"
    }

    func toggleWidgetSize(_ widget: PinnedWidget) {
        let current = widgetSizes[widget.rawValue] ?? "half"
        widgetSizes[widget.rawValue] = current == "half" ? "full" : "half"
    }

    // Computed from pinnedWidgets for backward compatibility
    var showMusic: Bool { pinnedWidgets.contains(.music) }
    var musicSize: MusicSize { pinnedWidgets.count > 1 ? .mini : .big }

    /// Height of the expanded content area (below the top-bar) for the Today view.
    /// Widgets render in a two-column grid, so each row contributes the height
    /// of its tallest widget. Clamped so a couple of widgets don't leave a
    /// mostly-empty notch, and so many widgets fall back to internal scrolling
    /// instead of growing the notch off-screen.
    var todayExpandedH: CGFloat {
        let spacing: CGFloat = 10
        var h: CGFloat = 80 + spacing  // clock card + gap
        var i = 0
        while i < pinnedWidgets.count {
            let w = pinnedWidgets[i]
            if widgetIsFullWidth(w) {
                h += w.gridHeight + spacing
                i += 1
            } else if i + 1 < pinnedWidgets.count && !widgetIsFullWidth(pinnedWidgets[i + 1]) {
                let row = [w, pinnedWidgets[i + 1]]
                h += (row.map(\.gridHeight).max() ?? 0) + spacing
                i += 2
            } else {
                h += w.gridHeight + spacing
                i += 1
            }
        }
        h += 46 + 10  // composer + bottom padding
        return min(max(h, 200), 320)
    }

    // UI state (persisted across restarts)
    @Published var collapsedGroups: Set<String> { didSet { save() } }

    static let defaultAnthropicModel = "claude-sonnet-4-6"

    init() {
        // Set defaults first
        openChatOnSend = true
        restoreLastView = false
        keepOpenInChat = true
        selectedDefaultModel = Self.defaultAnthropicModel
        pinnedWidgets = [.calendar, .music]
        showBattery = true
        showAgentLiveState = true
        compactAgentRows = false
        collapsedGroups = []
        widgetSizes = [:]

        // Then load from file
        load()
    }

    private func save() {
        let data: [String: Any] = [
            "openChatOnSend": openChatOnSend,
            "keepOpenInChat": keepOpenInChat,
            "restoreLastView": restoreLastView,
            "selectedDefaultModel": selectedDefaultModel,
            "pinnedWidgets": pinnedWidgets.map { $0.rawValue },
            "showBattery": showBattery,
            "showAgentLiveState": showAgentLiveState,
            "compactAgentRows": compactAgentRows,
            "collapsedGroups": Array(collapsedGroups),
            "widgetSizes": widgetSizes,
        ]
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true, attributes: nil)
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
        if let v = json["selectedDefaultModel"] as? String, !v.isEmpty { selectedDefaultModel = v }
        if let v = json["pinnedWidgets"] as? [String] {
            pinnedWidgets = v.compactMap { PinnedWidget(rawValue: $0) }
        } else {
            // Migrate from old settings
            var migrated: [PinnedWidget] = []
            if let cm = json["calendarMode"] as? String, cm != "off" {
                migrated.append(.calendar)
            }
            if let sm = json["showMusic"] as? Bool, sm {
                migrated.append(.music)
            }
            if !migrated.isEmpty { pinnedWidgets = migrated }
        }
        if let v = json["showBattery"] as? Bool { showBattery = v }
        if let v = json["showAgentLiveState"] as? Bool { showAgentLiveState = v }
        if let v = json["compactAgentRows"] as? Bool { compactAgentRows = v }
        if let v = json["collapsedGroups"] as? [String] { collapsedGroups = Set(v) }
        if let v = json["widgetSizes"] as? [String: String] { widgetSizes = v }
    }
}

enum APIConfig {
    static let baseURL = "http://localhost:3001"
}

private enum CachedFormatters {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm"; return f }()
    static let period: DateFormatter = { let f = DateFormatter(); f.dateFormat = "a"; return f }()
    static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    static let shortDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    static let shortTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
}

class NotchViewModel: ObservableObject {
    @Published var tasks: [SubagentTask] = []
    @Published var currentTime: Date = Date()
    @Published var viewState: NotchViewState = .overview
    @Published var isExpanded = false
    @Published var isQuickPrompt = false
    @Published var shimmerStep: Int = 0
    @Published var shouldFocusChatInput = false
    @Published var isChatInputActive = false
    var mouseInContent = false
    /// True while a widget is being dragged/reordered on the Today page.
    /// Prevents the panel from auto-collapsing if the cursor briefly leaves
    /// the shape bounds mid-drag.
    var isDraggingWidget = false
    var lastViewBeforeCollapse: NotchViewState = .overview

    var authManager: AuthManager?

    // App connection states (keyed by app_type: gmail, googlecalendar, googledocs, github)
    @Published var appConnected: [String: Bool] = [:]
    @Published var appLoading: [String: Bool] = [:]
    @Published var appError: [String: String?] = [:]

    // Provider configs (BYOK)
    @Published var providerConfigs: [ProviderConfig] = []
    @Published var providerLoading = false
    @Published var providerVerifying: [String: Bool] = [:]
    @Published var providerError: [String: String?] = [:]
    @Published var providerVerified: [String: Bool] = [:]
    @Published var modelOptions: [ProviderModelOption] = []
    @Published var activeModelProvider: String = "anthropic"
    @Published var isLoadingModels = false
    @Published var modelListError: String?

    // Billing / trial state
    @Published var billingStatus: BillingStatus?
    @Published var billingLoading = false
    @Published var billingError: String?
    private var checkoutPollTimer: Timer?
    private var checkoutPollAttempts = 0
    private let checkoutPollMaxAttempts = 40 // ~2 min at 3s intervals

    // WebSocket send callback (set by WebSocketServer)
    var wsSend: (([String: Any]) -> Void)?

    // Pending connection requests from agent (requestId → metadata)
    @Published var pendingConnectionRequests: [String: PendingConnectionRequest] = [:]

    @Published var settings = NotchSettings()
    @Published var agentMonitor = AgentMonitor()
    @Published var nowPlaying = NowPlayingMonitor()
    let statsMonitor = SystemStatsMonitor()
    private let localConversationStore = LocalConversationStore()
    private var clockTimer: Timer?
    private var shimmerTimer: Timer?
    private var agentMonitorCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []

    var timeString: String { CachedFormatters.time.string(from: currentTime) }
    var periodString: String { CachedFormatters.period.string(from: currentTime) }
    var dateString: String { CachedFormatters.date.string(from: currentTime) }
    var shortDateString: String { CachedFormatters.shortDate.string(from: currentTime) }
    var shortTimeString: String { CachedFormatters.shortTime.string(from: currentTime) }

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

    deinit {
        checkoutPollTimer?.invalidate()
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
        let records = localConversationStore.loadAll()
        isLoadingHistory = false
        threadHistory = records.map {
            ThreadSummary(
                id: $0.id,
                title: $0.title,
                updatedAt: Self.isoString($0.updatedAt)
            )
        }
        hydrateLocalConversationTasks(from: records)
    }

    func loadThread(_ threadId: String) {
        // If already loaded in tasks, just navigate
        if tasks.contains(where: { $0.threadId == threadId || $0.id == threadId }) {
            let taskId = tasks.first(where: { $0.threadId == threadId || $0.id == threadId })!.id
            withAnimation(DN.transition) { viewState = .agentChat(taskId) }
            return
        }

        guard let record = localConversationStore.load(id: threadId) else { return }

        let task = task(from: record)

        withAnimation(.snappy(duration: 0.3)) {
            self.tasks.insert(task, at: 0)
            self.viewState = .agentChat(record.id)
        }
    }

    private func hydrateLocalConversationTasks(from records: [LocalConversationRecord]) {
        guard !records.isEmpty else { return }

        var existingIds = Set<String>()
        for task in tasks {
            existingIds.insert(task.id)
            if let threadId = task.threadId {
                existingIds.insert(threadId)
            }
        }

        let restoredTasks: [SubagentTask] = records.compactMap { record in
            guard !existingIds.contains(record.id), !record.messages.isEmpty else { return nil }
            existingIds.insert(record.id)
            return task(from: record)
        }

        guard !restoredTasks.isEmpty else { return }
        tasks.append(contentsOf: restoredTasks)
    }

    private func task(from record: LocalConversationRecord) -> SubagentTask {
        SubagentTask(
            id: record.id,
            task: record.task,
            description: record.title,
            status: record.status,
            toolCallsCount: record.toolCallsCount,
            streamingText: "",
            result: record.messages.last(where: { $0.role == "agent" })?.content,
            createdAt: record.createdAt,
            completedAt: record.completedAt,
            activitySteps: [],
            chatHistory: record.messages,
            threadId: record.id,
            isFromHistory: false
        )
    }

    private func persistTask(_ task: SubagentTask) {
        guard !task.chatHistory.isEmpty else { return }

        let savedTitle = task.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = String((task.chatHistory.first(where: { $0.role == "user" })?.content ?? task.task).prefix(60))
        let title: String
        if let savedTitle, !savedTitle.isEmpty {
            title = savedTitle
        } else {
            title = fallbackTitle
        }
        let updatedAt = task.completedAt ?? task.chatHistory.last?.timestamp ?? Date()
        let record = LocalConversationRecord(
            id: task.threadId ?? task.id,
            title: title,
            task: task.task,
            status: task.status,
            createdAt: task.createdAt,
            updatedAt: updatedAt,
            completedAt: task.completedAt,
            toolCallsCount: task.toolCallsCount,
            messages: task.chatHistory
        )
        localConversationStore.upsert(record)
        loadThreadHistory()
    }

    private func persistTask(at idx: Int) {
        guard tasks.indices.contains(idx) else { return }
        persistTask(tasks[idx])
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    func interruptInProgressConversations() {
        localConversationStore.markInProgressInterrupted()
        for idx in tasks.indices where tasks[idx].isActive {
            tasks[idx].status = .cancelled
            tasks[idx].completedAt = Date()
            tasks[idx].streamingText = ""
            persistTask(at: idx)
            }
        loadThreadHistory()
    }

    // MARK: - Notifications

    @Published var notifications: [NotificationItem] = []
    @Published var unreadCount: Int = 0

    func loadNotifications() {
        guard let auth = authManager else { return }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else { return }

            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/notifications")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["notifications"] as? [[String: Any]] else { return }

            let parsed: [NotificationItem] = items.compactMap { n in
                guard let id = n["id"] as? String,
                      let title = n["title"] as? String else { return nil }
                return NotificationItem(
                    id: id, title: title,
                    body: (n["body"] as? String).map { Self.cleanNotifBody($0) },
                    source: n["source"] as? String ?? "system",
                    sourceId: n["source_id"] as? String,
                    read: n["read"] as? Bool ?? false,
                    createdAt: n["created_at"] as? String ?? ""
                )
            }

            await MainActor.run {
                self.notifications = parsed
                self.unreadCount = parsed.filter { !$0.read }.count
            }
        }
    }

    func loadUnreadCount() {
        guard let auth = authManager else { return }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else { return }

            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/notifications/unread-count")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = json["count"] as? Int else { return }

            await MainActor.run { self.unreadCount = count }
        }
    }

    func markNotificationRead(_ id: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].read = true
            unreadCount = notifications.filter { !$0.read }.count
        }
        guard let auth = authManager else { return }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else { return }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/notifications/\(id)/read")!)
            request.httpMethod = "POST"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func markAllRead() {
        notifications.indices.forEach { notifications[$0].read = true }
        unreadCount = 0
        guard let auth = authManager else { return }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else { return }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/notifications/read-all")!)
            request.httpMethod = "POST"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    // MARK: - Scheduled Tasks

    @Published var scheduledTasks: [ScheduledTask] = []

    func loadScheduledTasks() {
        guard let auth = authManager else { return }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else { return }

            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/scheduled")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tasks = json["tasks"] as? [[String: Any]] else {
                print("[Perch] loadScheduledTasks: failed status=\(status)")
                return
            }

            let parsed: [ScheduledTask] = tasks.compactMap { t in
                guard let id = t["id"] as? String,
                      let name = t["name"] as? String else { return nil }
                return ScheduledTask(
                    id: id,
                    name: name,
                    prompt: t["prompt"] as? String ?? "",
                    taskType: t["task_type"] as? String ?? "scheduled",
                    scheduleHuman: t["schedule_human"] as? String ?? "",
                    enabled: t["enabled"] as? Bool ?? true,
                    lastRunAt: t["last_run_at"] as? String,
                    nextRunAt: t["next_run_at"] as? String,
                    runCount: t["run_count"] as? Int ?? 0,
                    lastStatus: (t["last_result"] as? [String: Any])?["status"] as? String,
                    lastResultSummary: (t["last_result"] as? [String: Any])?["summary"] as? String,
                    notifyUser: t["notify_user"] as? Bool ?? false
                )
            }

            await MainActor.run {
                self.scheduledTasks = parsed
                print("[Perch] loadScheduledTasks: \(parsed.count) tasks")
            }
        }
    }

    func toggleScheduledTask(_ taskId: String, enabled: Bool) {
        guard let auth = authManager else { return }
        // Optimistic update
        if let idx = scheduledTasks.firstIndex(where: { $0.id == taskId }) {
            scheduledTasks[idx].enabled = enabled
        }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken,
                  let url = URL(string: "\(APIConfig.baseURL)/api/scheduled/\(taskId)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "PATCH"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func deleteScheduledTask(_ taskId: String) {
        guard let auth = authManager else { return }
        scheduledTasks.removeAll { $0.id == taskId }
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken,
                  let url = URL(string: "\(APIConfig.baseURL)/api/scheduled/\(taskId)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
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

    // MARK: - App Connections (Generic)

    func checkAppStatus(_ appType: String) {
        guard let auth = authManager else { return }
        appLoading[appType] = true
        appError[appType] = nil          // clear any stale error from a previous connect attempt
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run { self.appLoading[appType] = false }
                return
            }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/apps/\(appType)/status")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connected = json["connected"] as? Bool else {
                await MainActor.run { self.appLoading[appType] = false }
                return
            }
            await MainActor.run {
                self.appConnected[appType] = connected
                self.appLoading[appType] = false
            }
        }
    }

    func connectApp(_ appType: String) {
        guard let auth = authManager else { return }
        appLoading[appType] = true
        appError[appType] = nil
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run {
                    self.appError[appType] = "Not authenticated"
                    self.appLoading[appType] = false
                }
                return
            }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/apps/\(appType)/connect")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run {
                    self.appError[appType] = "Failed to reach server"
                    self.appLoading[appType] = false
                }
                return
            }

            if let error = json["error"] as? String {
                await MainActor.run {
                    self.appError[appType] = error
                    self.appLoading[appType] = false
                }
                return
            }

            if json["already_connected"] as? Bool == true {
                await MainActor.run {
                    self.appConnected[appType] = true
                    self.appLoading[appType] = false
                }
                return
            }

            if let redirectUrl = json["redirectUrl"] as? String,
               let url = URL(string: redirectUrl) {
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
                // Poll for connection until OAuth completes (up to 2 minutes)
                for _ in 0..<40 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    var statusReq = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/apps/\(appType)/status")!)
                    statusReq.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    if let (sData, _) = try? await URLSession.shared.data(for: statusReq),
                       let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                       sJson["connected"] as? Bool == true {
                        await MainActor.run {
                            self.appConnected[appType] = true
                            self.appLoading[appType] = false
                        }
                        return
                    }
                }
                await MainActor.run { self.appLoading[appType] = false }
                return
            }

            // Auto-connected (no redirect needed)
            if json["connected"] as? Bool == true {
                await MainActor.run {
                    self.appConnected[appType] = true
                    self.appLoading[appType] = false
                }
                return
            }

            await MainActor.run { self.appLoading[appType] = false }
        }
    }

    func disconnectApp(_ appType: String) {
        guard let auth = authManager else { return }
        appLoading[appType] = true
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run { self.appLoading[appType] = false }
                return
            }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/apps/\(appType)/disconnect")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            _ = try? await URLSession.shared.data(for: request)
            await MainActor.run {
                self.appConnected[appType] = false
                self.appLoading[appType] = false
            }
        }
    }

    func resetApp(_ appType: String) {
        appError[appType] = nil
        appLoading[appType] = false
    }

    // MARK: - Billing

    func loadBillingStatus() {
        guard let auth = authManager, let token = auth.accessToken else { return }
        billingLoading = true
        billingError = nil

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/billing/status")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                await MainActor.run {
                    self.billingLoading = false
                    self.billingError = "Cannot reach billing service"
                }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            guard status == 200 else {
                let message = json["error"] as? String ?? "Billing status unavailable"
                await MainActor.run {
                    self.billingLoading = false
                    self.billingError = message
                    if status == 404 {
                        self.authManager?.logout()
                    }
                }
                return
            }

            let parsed = BillingStatus(
                billingStatus: json["billingStatus"] as? String ?? "trialing",
                trialStartedAt: json["trialStartedAt"] as? String,
                trialEndsAt: json["trialEndsAt"] as? String,
                trialDaysRemaining: json["trialDaysRemaining"] as? Int ?? 0,
                lifetimePurchasedAt: json["lifetimePurchasedAt"] as? String,
                hasActiveProvider: json["hasActiveProvider"] as? Bool ?? false,
                activeProvider: json["activeProvider"] as? String,
                canUseServerKey: json["canUseServerKey"] as? Bool ?? false,
                requiresPurchase: json["requiresPurchase"] as? Bool ?? false,
                requiresProviderKey: json["requiresProviderKey"] as? Bool ?? false
            )

            await MainActor.run {
                self.billingStatus = parsed
                self.billingLoading = false
                self.billingError = nil
                if parsed.billingStatus == "paid" {
                    self.stopCheckoutPolling()
                }
            }
        }
    }

    private func stopCheckoutPolling() {
        checkoutPollTimer?.invalidate()
        checkoutPollTimer = nil
        checkoutPollAttempts = 0
    }

    private func startCheckoutPolling() {
        stopCheckoutPolling() // invalidate any existing timer so repeated "Buy $5" taps never leak timers
        checkoutPollAttempts = 0
        checkoutPollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkoutPollAttempts += 1
            if self.checkoutPollAttempts >= self.checkoutPollMaxAttempts {
                self.stopCheckoutPolling()
                return
            }
            self.loadBillingStatus()
        }
    }

    func startCheckout() {
        guard let auth = authManager, let token = auth.accessToken else { return }
        billingLoading = true
        billingError = nil

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/billing/checkout")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [:] as [String: Any])

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                await MainActor.run {
                    self.billingLoading = false
                    self.billingError = "Cannot start checkout"
                }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            await MainActor.run {
                self.billingLoading = false
                if status == 200, let urlString = json["checkout_url"] as? String, let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                    self.startCheckoutPolling()
                } else {
                    self.billingError = json["error"] as? String ?? "Checkout is not ready yet"
                }
            }
        }
    }

    // MARK: - Provider Config (BYOK)

    func loadProviderConfigs() {
        guard let auth = authManager, let token = auth.accessToken else { return }
        providerLoading = true

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let configs = json["configs"] as? [[String: Any]] else {
                await MainActor.run { self.providerLoading = false }
                return
            }

            let parsed: [ProviderConfig] = configs.compactMap { c in
                guard let id = c["id"] as? String,
                      let provider = c["provider"] as? String,
                      let modelId = c["model_id"] as? String else { return nil }
                return ProviderConfig(
                    id: id,
                    provider: provider,
                    modelId: modelId,
                    isActive: c["is_active"] as? Bool ?? false,
                    verifiedAt: c["verified_at"] as? String
                )
            }

            await MainActor.run {
                self.providerConfigs = parsed
                self.providerLoading = false
                if let active = parsed.first(where: { $0.isActive }) {
                    self.activeModelProvider = active.provider
                    if self.settings.selectedDefaultModel.isEmpty {
                        self.settings.selectedDefaultModel = active.modelId
                    }
                }
                self.loadProviderModels()
            }
        }
    }

    func loadProviderModels() {
        guard let auth = authManager, let token = auth.accessToken else {
            let provider = activeProviderType
            activeModelProvider = provider
            modelOptions = fallbackModelOptions(for: provider)
            ensureSelectedModelIsAvailable(activeModel: settings.selectedDefaultModel)
            return
        }

        isLoadingModels = true
        modelListError = nil

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider/models")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                await MainActor.run {
                    self.isLoadingModels = false
                    self.modelListError = "Model list unavailable"
                    let provider = self.activeProviderType
                    self.activeModelProvider = provider
                    self.modelOptions = self.fallbackModelOptions(for: provider)
                    self.ensureSelectedModelIsAvailable(activeModel: self.settings.selectedDefaultModel)
                }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let provider = json["provider"] as? String ?? self.activeProviderType
            let activeModel = json["active_model"] as? String
            let warning = json["warning"] as? String
            let models = (json["models"] as? [[String: Any]] ?? []).compactMap { item -> ProviderModelOption? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                return ProviderModelOption(
                    id: id,
                    name: item["name"] as? String ?? id,
                    provider: provider,
                    contextLength: item["context_length"] as? Int
                )
            }

            await MainActor.run {
                self.isLoadingModels = false
                self.activeModelProvider = provider
                self.modelOptions = models.isEmpty ? self.fallbackModelOptions(for: provider) : models
                self.modelListError = status == 200 ? warning : (json["error"] as? String ?? "Model list unavailable")
                self.ensureSelectedModelIsAvailable(activeModel: activeModel)
            }
        }
    }

    func selectModel(_ modelId: String) {
        guard !modelId.isEmpty else { return }
        settings.selectedDefaultModel = modelId
    }

    private func selectedModelIdForRequest() -> String {
        if modelOptions.isEmpty {
            let fallbackOptions = fallbackModelOptions(for: activeProviderType)
            if !fallbackOptions.contains(where: { $0.id == settings.selectedDefaultModel }),
               let fallback = fallbackOptions.first?.id {
                settings.selectedDefaultModel = fallback
            }
            return settings.selectedDefaultModel
        }

        if !modelOptions.contains(where: { $0.id == settings.selectedDefaultModel }) {
            ensureSelectedModelIsAvailable(activeModel: nil)
        }
        return settings.selectedDefaultModel
    }

    var activeProviderType: String {
        providerConfigs.first(where: { $0.isActive })?.provider ?? "anthropic"
    }

    private func ensureSelectedModelIsAvailable(activeModel: String?) {
        let availableIds = Set(modelOptions.map(\.id))
        if availableIds.contains(settings.selectedDefaultModel) {
            return
        }
        if let activeModel, availableIds.contains(activeModel) {
            settings.selectedDefaultModel = activeModel
            return
        }
        settings.selectedDefaultModel = activeModel ?? modelOptions.first?.id ?? NotchSettings.defaultAnthropicModel
    }

    private func fallbackModelOptions(for provider: String) -> [ProviderModelOption] {
        let models = ProviderConfig.availableModels[provider] ?? ProviderConfig.availableModels["anthropic"] ?? []
        return models.map {
            ProviderModelOption(id: $0.id, name: $0.label, provider: provider, contextLength: nil)
        }
    }

    func saveProviderConfig(provider: String, apiKey: String, modelId: String) {
        guard let auth = authManager, let token = auth.accessToken else { return }

        providerError[provider] = nil

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = ["provider": provider, "api_key": apiKey, "model_id": modelId]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                await MainActor.run { self.providerError[provider] = "Network error" }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            if status == 200 {
                await MainActor.run {
                    self.providerError[provider] = nil
                    self.loadProviderConfigs()
                    self.loadProviderModels()
                    self.loadBillingStatus()
                }
            } else {
                let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                await MainActor.run {
                    self.providerError[provider] = errorMsg ?? "Save failed"
                }
            }
        }
    }

    func verifyProviderKey(provider: String, apiKey: String, modelId: String) {
        guard let auth = authManager, let token = auth.accessToken else { return }

        providerVerifying[provider] = true
        providerVerified[provider] = false
        providerError[provider] = nil

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider/verify")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let body: [String: Any] = ["provider": provider, "api_key": apiKey, "model_id": modelId]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                await MainActor.run {
                    self.providerVerifying[provider] = false
                    self.providerError[provider] = "Network error"
                }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

            await MainActor.run {
                self.providerVerifying[provider] = false
                if status == 200 && json["verified"] as? Bool == true {
                    self.providerVerified[provider] = true
                    self.providerError[provider] = nil
                } else {
                    self.providerVerified[provider] = false
                    self.providerError[provider] = json["error"] as? String ?? "Verification failed"
                }
            }
        }
    }

    func activateProviderConfig(provider: String) {
        guard let auth = authManager, let token = auth.accessToken else { return }
        providerError[provider] = nil

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider/activate")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": provider])

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                await MainActor.run { self.providerError[provider] = "Network error" }
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                await MainActor.run {
                    self.providerError[provider] = nil
                    self.loadProviderConfigs()
                    self.loadProviderModels()
                    self.loadBillingStatus()
                }
            } else {
                let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                await MainActor.run {
                    self.providerError[provider] = errorMsg ?? "Activate failed"
                }
            }
        }
    }

    func deactivateAllProviders() {
        guard let auth = authManager, let token = auth.accessToken else { return }

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider/default")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [:] as [String: Any])

            _ = try? await URLSession.shared.data(for: request)
            await MainActor.run {
                for idx in self.providerConfigs.indices {
                    self.providerConfigs[idx].isActive = false
                }
                self.providerError = [:]
                self.activeModelProvider = "anthropic"
                self.loadProviderConfigs()
                self.loadProviderModels()
                self.loadBillingStatus()
            }
        }
    }

    func deleteProviderConfig(provider: String) {
        guard let auth = authManager, let token = auth.accessToken else { return }

        Task {
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/provider")!)
            request.httpMethod = "DELETE"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": provider])

            _ = try? await URLSession.shared.data(for: request)
            await MainActor.run {
                self.providerConfigs.removeAll { $0.provider == provider }
                self.providerError[provider] = nil
                self.providerVerified[provider] = false
                self.loadProviderModels()
                self.loadBillingStatus()
            }
        }
    }

    // MARK: - Event Processing

    func processEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "subagent_event": processSubagentEvent(json)
        case "task_summary": processBulkUpdate(json)
        case "notification": processNotification(json)
        case "peek_notification": processPeekNotification(json)
        case "connection_request": processConnectionRequest(json)
        default: break
        }
    }

    private func processConnectionRequest(_ json: [String: Any]) {
        guard let requestId = json["request_id"] as? String,
              let sessionId = json["session_id"] as? String,
              let appType = json["app_type"] as? String,
              let displayName = json["display_name"] as? String,
              let reason = json["reason"] as? String else { return }

        let request = PendingConnectionRequest(
            requestId: requestId, sessionId: sessionId,
            appType: appType, displayName: displayName,
            reason: reason, status: .pending
        )
        pendingConnectionRequests[requestId] = request

        // Add to the task's chat history as a special message
        if let idx = tasks.firstIndex(where: { $0.id == sessionId }) {
            withAnimation(.snappy(duration: 0.3)) {
                tasks[idx].chatHistory.append(ChatMessage(
                    id: requestId, role: "connection_request",
                    content: reason, toolName: appType,
                    toolInput: displayName, toolOutput: nil,
                    draftCard: nil, timestamp: Date()
                ))
            }
            persistTask(at: idx)
        }
    }

    func approveConnectionRequest(_ requestId: String) {
        guard var request = pendingConnectionRequests[requestId] else { return }
        request.status = .connecting
        pendingConnectionRequests[requestId] = request

        // Update the chat message to show connecting state
        updateConnectionRequestMessage(requestId, status: .connecting)

        let appType = request.appType

        // Start the OAuth connection flow
        connectApp(appType)

        // Poll until connected, then send response
        Task {
            var attempts = 0
            while attempts < 24 { // 120s total (24 × 5s)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                attempts += 1

                if await MainActor.run(body: { self.appConnected[appType] == true }) {
                    await MainActor.run {
                        self.pendingConnectionRequests[requestId]?.status = .approved
                        self.updateConnectionRequestMessage(requestId, status: .approved)
                        self.wsSend?([
                            "type": "connection_response",
                            "request_id": requestId,
                            "approved": true,
                        ])
                    }
                    return
                }
            }

            // Timed out waiting for connection
            await MainActor.run {
                self.pendingConnectionRequests[requestId]?.status = .denied
                self.updateConnectionRequestMessage(requestId, status: .denied)
                self.wsSend?([
                    "type": "connection_response",
                    "request_id": requestId,
                    "approved": false,
                ])
            }
        }
    }

    func denyConnectionRequest(_ requestId: String) {
        guard var request = pendingConnectionRequests[requestId] else { return }
        request.status = .denied
        pendingConnectionRequests[requestId] = request

        updateConnectionRequestMessage(requestId, status: .denied)

        wsSend?([
            "type": "connection_response",
            "request_id": requestId,
            "approved": false,
        ])
    }

    private func updateConnectionRequestMessage(_ requestId: String, status: ConnectionRequestStatus) {
        guard let request = pendingConnectionRequests[requestId],
              let taskIdx = tasks.firstIndex(where: { $0.id == request.sessionId }),
              let msgIdx = tasks[taskIdx].chatHistory.firstIndex(where: { $0.id == requestId }) else { return }

        withAnimation(.snappy(duration: 0.2)) {
            // Store the status in toolOutput so the UI can read it
            tasks[taskIdx].chatHistory[msgIdx].toolOutput = status.rawValue
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
            // If this is a title-only update (has "title" key), only update description
            if let title = data["title"] as? String {
                withAnimation(.easeOut(duration: 0.2)) {
                    tasks[idx].task = title
                    tasks[idx].description = title
                }
                persistTask(at: idx)
                return
            }
            tasks[idx].status = TaskStatus(rawValue: data["status"] as? String ?? "running") ?? .running
            if let desc = data["description"] as? String { tasks[idx].description = desc }
            if let count = data["tool_calls_count"] as? Int { tasks[idx].toolCallsCount = count }
            persistTask(at: idx)
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
            case "text_flush":
                if let text = data["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tasks[idx].chatHistory.append(ChatMessage(
                        id: UUID().uuidString, role: "agent", content: text,
                        toolName: nil, draftCard: nil, timestamp: Date()
                    ))
                    tasks[idx].streamingText = ""
                }
            case "tool_start":
                let toolName = data["tool_name"] as? String
                let toolInput = data["tool_input"] as? String
                tasks[idx].currentToolName = toolName
                // Add tool call to chat history (will be updated with output on tool_result)
                tasks[idx].chatHistory.append(ChatMessage(
                    id: UUID().uuidString, role: "tool", content: "",
                    toolName: toolName, toolInput: toolInput, toolOutput: nil,
                    draftCard: nil, timestamp: Date()
                ))
            case "tool_result":
                tasks[idx].toolCallsCount += 1
                tasks[idx].currentToolName = nil
                let toolOutput = data["tool_output"] as? String
                // Update the last tool message with output
                if let lastToolIdx = tasks[idx].chatHistory.lastIndex(where: { $0.role == "tool" }) {
                    tasks[idx].chatHistory[lastToolIdx].toolOutput = toolOutput
                    tasks[idx].chatHistory[lastToolIdx].content = toolOutput ?? ""
                }
            case "thinking_complete":
                if let text = data["text"] as? String { tasks[idx].streamingText = text }
            default: break
            }
        }
        if progressType == "text_flush" || progressType == "tool_start" || progressType == "tool_result" {
            persistTask(at: idx)
        }
    }

    private func handleDone(sessionId: String, data: [String: Any]) {
        guard let idx = tasks.firstIndex(where: { $0.id == sessionId }) else { return }
        let statusStr = data["status"] as? String ?? "completed"
        withAnimation(.snappy(duration: 0.3)) {
            tasks[idx].status = TaskStatus(rawValue: statusStr) ?? .completed
            tasks[idx].completedAt = Date()
            tasks[idx].currentToolName = nil
            tasks[idx].streamingText = ""
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
        persistTask(at: idx)
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

    private func processNotification(_ json: [String: Any]) {
        guard let data = json["data"] as? [String: Any],
              let id = data["id"] as? String,
              let title = data["title"] as? String else { return }

        let body = Self.cleanNotifBody(data["body"] as? String ?? "")
        let item = NotificationItem(
            id: id,
            title: title,
            body: body,
            source: data["source"] as? String ?? "system",
            sourceId: data["source_id"] as? String,
            read: false,
            createdAt: data["created_at"] as? String ?? ""
        )

        insertOrUpdateNotification(item)
        showPeek(title: title, body: body)

        loadScheduledTasks()
    }

    // MARK: - Peek Notification

    @Published var isPeeking = false
    @Published var peekTitle: String = ""
    @Published var peekBody: String = ""
    @Published var peekHovering = false

    private func processPeekNotification(_ json: [String: Any]) {
        guard let data = json["data"] as? [String: Any],
              let id = data["id"] as? String,
              let title = data["title"] as? String else { return }

        let body = Self.cleanNotifBody(data["body"] as? String ?? "")

        let item = NotificationItem(
            id: id,
            title: title,
            body: body,
            source: data["source"] as? String ?? "system",
            sourceId: data["source_id"] as? String,
            read: false,
            createdAt: data["created_at"] as? String ?? ""
        )

        insertOrUpdateNotification(item)
        showPeek(title: title, body: body)

        loadScheduledTasks()
    }

    private func insertOrUpdateNotification(_ item: NotificationItem) {
        if let idx = notifications.firstIndex(where: { $0.id == item.id }) {
            notifications[idx] = item
        } else {
            withAnimation(.snappy(duration: 0.3)) {
                notifications.insert(item, at: 0)
                unreadCount += item.read ? 0 : 1
            }
        }
        unreadCount = notifications.filter { !$0.read }.count
    }

    private func showPeek(title: String, body: String) {
        // Soft peek — don't fully expand, just grow the notch slightly
        withAnimation(.snappy(duration: 0.35)) {
            peekTitle = title
            peekBody = String(Self.cleanNotifBody(body).prefix(300))
            isPeeking = true
        }

        // Auto-dismiss after 4 seconds unless hovering
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.peekHovering else { return }
            self.dismissPeek()
        }
    }

    func dismissPeek() {
        withAnimation(.easeOut(duration: 0.25)) {
            isPeeking = false
            peekHovering = false
        }
    }

    // MARK: - Notification Body Cleaning

    /// Strips tool call/response XML blocks from notification bodies so raw
    /// agent internals don't leak into the peek bar or notification list.
    static func cleanNotifBody(_ text: String) -> String {
        var result = text
        // Strip <tool_call>...</tool_call> and <tool_response>...</tool_response> blocks
        let patterns = ["<tool_call>[\\s\\S]*?</tool_call>", "<tool_response>[\\s\\S]*?</tool_response>"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    // Promote to active if it was from history
                    tasks[idx].isFromHistory = false
                }
                persistTask(at: idx)
            }
        } else {
            // New task
            let task = SubagentTask(
                id: sid,
                task: message,
                description: "New Chat",
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
                ],
                threadId: sid
            )
            withAnimation(.snappy(duration: 0.3)) {
                tasks.insert(task, at: 0)
                if settings.openChatOnSend {
                    viewState = .agentChat(sid)
                }
                // else: stay on current page, task appears in background
            }
            persistTask(task)
        }

        // POST to backend (refresh token first if needed)
        let auth = authManager
        let historyForRequest = recentHistoryPayload(for: sid, currentMessage: message)
        Task {
            await auth?.ensureValidToken()
            guard let url = URL(string: "\(APIConfig.baseURL)/api/chat") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = auth?.accessToken {
                request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let body: [String: Any] = [
                "message": message,
                "session_id": sid,
                "conversation_id": sid,
                "model_id": selectedModelIdForRequest(),
                "history": historyForRequest,
            ]
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

    private func recentHistoryPayload(for sessionId: String, currentMessage: String) -> [[String: String]] {
        guard let task = tasks.first(where: { $0.id == sessionId }) else { return [] }
        var messages = task.chatHistory.filter { $0.role == "user" || $0.role == "agent" }
        if let last = messages.last, last.role == "user", last.content == currentMessage {
            messages.removeLast()
        }
        return messages.suffix(24).map {
            [
                "role": $0.role == "agent" ? "assistant" : "user",
                "content": $0.content,
            ]
        }
    }
}
