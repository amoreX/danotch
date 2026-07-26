import AppKit
#if canImport(ExecutorCore)
import ExecutorCore
#endif
import Foundation
import SwiftUI
import Combine
import UserNotifications

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
    private static let onboardingConfigFile = configDir.appendingPathComponent("onboarding.json")

    // Chat behavior
    @Published var openChatOnSend: Bool        { didSet { save() } }
    @Published var restoreLastView: Bool       { didSet { save() } }
    @Published var keepOpenInChat: Bool        { didSet { save() } }
    @Published var selectedDefaultModel: String { didSet { save() } }
    @Published var userName: String            { didSet { save() } }

    // Display — pinned widgets
    @Published var pinnedWidgets: [PinnedWidget] { didSet { save() } }
    @Published var showBattery: Bool           { didSet { save() } }

    // Agents
    @Published var showAgentLiveState: Bool    { didSet { save() } }
    @Published var compactAgentRows: Bool      { didSet { save() } }

    // Privacy / local access
    @Published var agentMonitoringEnabled: Bool { didSet { save() } }
    @Published var musicControlsEnabled: Bool   { didSet { save() } }
    @Published var systemNotificationsEnabled: Bool { didSet { save() } }

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

    static let defaultAnthropicModel = "claude-haiku-4-5"

    init() {
        // Set defaults first
        openChatOnSend = true
        restoreLastView = false
        keepOpenInChat = true
        selectedDefaultModel = Self.defaultAnthropicModel
        userName = ""
        pinnedWidgets = [.calendar, .music]
        showBattery = true
        showAgentLiveState = true
        compactAgentRows = false
        agentMonitoringEnabled = false
        musicControlsEnabled = false
        systemNotificationsEnabled = false
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
            "userName": userName,
            "pinnedWidgets": pinnedWidgets.map { $0.rawValue },
            "showBattery": showBattery,
            "showAgentLiveState": showAgentLiveState,
            "compactAgentRows": compactAgentRows,
            "agentMonitoringEnabled": agentMonitoringEnabled,
            "musicControlsEnabled": musicControlsEnabled,
            "systemNotificationsEnabled": systemNotificationsEnabled,
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
        if let v = json["userName"] as? String { userName = v }
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
        if let v = json["agentMonitoringEnabled"] as? Bool { agentMonitoringEnabled = v }
        if let v = json["musicControlsEnabled"] as? Bool { musicControlsEnabled = v }
        if let v = json["systemNotificationsEnabled"] as? Bool { systemNotificationsEnabled = v }
        migrateOnboardingPrivacySettingsIfNeeded(currentSettings: json)
        if let v = json["collapsedGroups"] as? [String] { collapsedGroups = Set(v) }
        if let v = json["widgetSizes"] as? [String: String] { widgetSizes = v }
    }

    private func migrateOnboardingPrivacySettingsIfNeeded(currentSettings: [String: Any]) {
        guard currentSettings["agentMonitoringEnabled"] == nil
                || currentSettings["musicControlsEnabled"] == nil
                || currentSettings["systemNotificationsEnabled"] == nil,
              let data = try? Data(contentsOf: Self.onboardingConfigFile),
              let onboarding = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if currentSettings["agentMonitoringEnabled"] == nil,
           let value = onboarding["agent_monitoring"] as? Bool {
            agentMonitoringEnabled = value
        }
        if currentSettings["musicControlsEnabled"] == nil,
           let value = onboarding["music_controls"] as? Bool {
            musicControlsEnabled = value
        }
        if currentSettings["systemNotificationsEnabled"] == nil,
           let value = onboarding["system_notifications"] as? Bool {
            systemNotificationsEnabled = value
        }
    }
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

    let daemonConnection: LocalDaemonConnection
    @Published var connectionState: LocalDaemonConnectionState = .discovering
    @Published var connectionAnnouncement = ""
    private var installationID: String?
    private let installationIdentities: LocalInstallationIdentityStore
    private let accountDataStore: AccountDataStore
    private let deviceIdentities: DeviceIdentityProviding
    private let workspaceBookmarkResolver: WorkspaceBookmarkResolving
    private let workspaceBookmarks: ExecutorWorkspaceBookmarkStore
    private let executorInstallation: ExecutorInstallationVerifying
    private let executionBackend: DeviceExecutionBackend
    private let executionRequests: LocalExecutionRequestProcessor

    // App connection states (keyed by app_type: gmail, googlecalendar, googledocs, github)
    @Published var appConnected: [String: Bool] = [:]
    @Published var appLoading: [String: Bool] = [:]
    @Published var appError: [String: String?] = [:]
    @Published var appConnectionStatus: [String: String] = [:]

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

    @Published var requestedProviderType: String?
    @Published var composioState = ComposioConfigState(configured: false, connectedApps: [])

    // Pending connection requests from agent (requestId → metadata)
    @Published var pendingConnectionRequests: [String: PendingConnectionRequest] = [:]

    @Published var settings: NotchSettings
    @Published var agentMonitor: AgentMonitor
    @Published var nowPlaying: NowPlayingMonitor
    let statsMonitor = SystemStatsMonitor()
    private let localConversationStore: LocalConversationStore
    private var clockTimer: Timer?
    private var shimmerTimer: Timer?
    private var agentMonitorCancellable: AnyCancellable?
    private var settingsCancellable: AnyCancellable?
    private var cancellables: Set<AnyCancellable> = []
    private var selectedExecutionWorkspaces: [String: URL] = [:]

    var timeString: String { CachedFormatters.time.string(from: currentTime) }
    var periodString: String { CachedFormatters.period.string(from: currentTime) }
    var dateString: String { CachedFormatters.date.string(from: currentTime) }
    var shortDateString: String { CachedFormatters.shortDate.string(from: currentTime) }
    var shortTimeString: String { CachedFormatters.shortTime.string(from: currentTime) }

    init(
        localConversationStore: LocalConversationStore = LocalConversationStore(),
        daemonConnection: LocalDaemonConnection = LocalDaemonConnection(),
        installationIdentities: LocalInstallationIdentityStore = LocalInstallationIdentityStore(),
        accountDataStore: AccountDataStore = AccountDataStore(),
        deviceIdentities: DeviceIdentityProviding = DeviceIdentityStore(),
        workspaceBookmarkResolver: WorkspaceBookmarkResolving = SecurityScopedBookmarkResolver(),
        executorInstallation: ExecutorInstallationVerifying = ProductionExecutorInstallationVerifier(),
        executorBackend: DeviceExecutionBackend? = nil
    ) {
        let settings = NotchSettings()
        self.settings = settings
        self.agentMonitor = AgentMonitor(enabled: settings.agentMonitoringEnabled)
        self.nowPlaying = NowPlayingMonitor(enabled: settings.musicControlsEnabled)
        self.localConversationStore = localConversationStore
        self.daemonConnection = daemonConnection
        self.installationIdentities = installationIdentities
        self.accountDataStore = accountDataStore
        self.deviceIdentities = deviceIdentities
        self.workspaceBookmarkResolver = workspaceBookmarkResolver
        let workspaceBookmarks = ExecutorWorkspaceBookmarkStore(accountData: accountDataStore)
        self.workspaceBookmarks = workspaceBookmarks
        self.executorInstallation = executorInstallation
        let backend = executorBackend ?? ProductionExecutorBackend(
            identities: deviceIdentities,
            bookmarks: workspaceBookmarks,
            installation: executorInstallation
        )
        self.executionBackend = backend
        self.executionRequests = LocalExecutionRequestProcessor(
            backend: backend,
            accountData: accountDataStore
        )
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
        settings.$agentMonitoringEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.agentMonitor.setEnabled(enabled)
            }
            .store(in: &cancellables)
        settings.$musicControlsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.nowPlaying.setEnabled(enabled)
            }
            .store(in: &cancellables)
        daemonConnection.$state.sink { [weak self] state in
            self?.connectionState = state
        }.store(in: &cancellables)
        daemonConnection.onStateAnnouncement = { [weak self] message in
            self?.connectionAnnouncement = message
        }
        daemonConnection.onEvent = { [weak self] installationID, event in
            guard let self, self.installationID == installationID else { return }
            self.processEvent(event)
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

    func activateLocalInstallation() {
        localConversationStore.activate(installationID: nil)
        tasks = []
        threadHistory = []
        notifications = []
        unreadCount = 0
        scheduledTasks = []
        pendingConnectionRequests = [:]
        appConnected = [:]
        providerConfigs = []
        requestedProviderType = nil
        viewState = .overview
        dismissPeek()
        do {
            let identity = try installationIdentities.loadOrCreate()
            installationID = identity.id
            localConversationStore.activate(installationID: identity.id)
            try? accountDataStore.importLegacyConversations(installationID: identity.id)
            daemonConnection.start()
        } catch {
            connectionState = .offline(reason: "Could not create the local installation identity.")
        }
    }

    func retryDaemonConnection() {
        daemonConnection.retry()
    }

    func cancelDaemonConnection() {
        daemonConnection.cancel()
    }

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

        // `records` is already sorted most-recent-first by loadAll(). Perch is
        // designed to run indefinitely in the background, and this used to
        // hydrate every historical conversation ever saved into the in-memory
        // `tasks` array with no cap — over months of use that's unbounded RAM
        // growth (every past chatHistory held live forever). Cap to a
        // reasonable recent window; older threads are still on disk and can be
        // opened on demand via loadThread(_:).
        let maxHydratedThreads = 50
        var restoredTasks: [SubagentTask] = []
        for record in records {
            guard !existingIds.contains(record.id), !record.messages.isEmpty else { continue }
            existingIds.insert(record.id)
            restoredTasks.append(task(from: record))
            if restoredTasks.count >= maxHydratedThreads { break }
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
            provider: record.provider,
            modelId: record.modelId,
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
        let recordId = task.threadId ?? task.id
        let record = LocalConversationRecord(
            id: recordId,
            title: title,
            task: task.task,
            status: task.status,
            createdAt: task.createdAt,
            updatedAt: updatedAt,
            completedAt: task.completedAt,
            toolCallsCount: task.toolCallsCount,
            messages: task.chatHistory,
            provider: task.provider,
            modelId: task.modelId
        )
        localConversationStore.upsert(record)

        // NOTE: this used to call loadThreadHistory() here, which does a full
        // disk read+decode of the whole conversations.json file. persistTask
        // fires on every tool_start/tool_result/text_flush WebSocket event —
        // during an active agent run that's a full file read AND write on the
        // main thread multiple times a second (compounding the write cost
        // fixed in LocalConversationStore.upsert above). The `tasks` array is
        // already the live source of truth for the active chat UI, so we only
        // need to keep the `threadHistory` sidebar summary in sync, which we
        // can do in-memory from the record we just built — no disk round trip.
        let summary = ThreadSummary(id: recordId, title: record.title, updatedAt: Self.isoString(updatedAt))
        if let idx = threadHistory.firstIndex(where: { $0.id == recordId }) {
            threadHistory[idx] = summary
        } else {
            threadHistory.insert(summary, at: 0)
        }
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
        Task {
            guard let data = try? await daemonConnection.request("/v1/notifications"),
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
        Task {
            guard let data = try? await daemonConnection.request("/v1/notifications/unread-count"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = json["count"] as? Int else { return }

            await MainActor.run {
                self.unreadCount = count
            }
        }
    }

    func markNotificationRead(_ id: String) {
        guard let idx = notifications.firstIndex(where: { $0.id == id }) else { return }
        // Already read: nothing to do (also covers repeat taps on no-body rows).
        if notifications[idx].read { return }
        let previous = notifications[idx].read
        notifications[idx].read = true
        unreadCount = notifications.filter { !$0.read }.count

        Task {
            if (try? await daemonConnection.request(
                "/v1/notifications/\(id)/read",
                method: "POST",
                json: [:]
            )) == nil {
                await MainActor.run { self.revertNotificationRead(id, to: previous) }
            }
        }
    }

    private func revertNotificationRead(_ id: String, to previous: Bool) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].read = previous
            unreadCount = notifications.filter { !$0.read }.count
        }
    }

    func markAllRead() {
        let previous = notifications.map { $0.read }
        notifications.indices.forEach { notifications[$0].read = true }
        unreadCount = 0
        Task {
            if (try? await daemonConnection.request(
                "/v1/notifications/read-all",
                method: "POST",
                json: [:]
            )) == nil {
                await MainActor.run { self.restoreNotificationReadStates(previous) }
            }
        }
    }

    private func restoreNotificationReadStates(_ previous: [Bool]) {
        guard previous.count == notifications.count else { return }
        for (i, wasRead) in previous.enumerated() { notifications[i].read = wasRead }
        unreadCount = notifications.filter { !$0.read }.count
    }

    // MARK: - Scheduled Tasks

    @Published var scheduledTasks: [ScheduledTask] = []
    @Published var scheduledTaskError: String?

    func loadScheduledTasks() {
        Task {
            guard let data = try? await daemonConnection.request("/v1/scheduled"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tasks = json["tasks"] as? [[String: Any]] else { return }

            let parsed: [ScheduledTask] = tasks.compactMap { t in
                guard let id = t["id"] as? String,
                      let name = t["name"] as? String else { return nil }
                return ScheduledTask(
                    id: id,
                    name: name,
                    prompt: t["prompt"] as? String ?? "",
                    taskType: t["task_type"] as? String ?? "scheduled",
                    scheduleHuman: t["schedule_human"] as? String ?? "",
                    cron: t["cron"] as? String,
                    intervalMs: t["interval_ms"] as? Int,
                    enabled: t["enabled"] as? Bool ?? true,
                    lastRunAt: t["last_run_at"] as? String,
                    nextRunAt: t["next_run_at"] as? String,
                    runCount: t["run_count"] as? Int ?? 0,
                    lastStatus: (t["last_result"] as? [String: Any])?["status"] as? String,
                    lastResultSummary: (t["last_result"] as? [String: Any])?["summary"] as? String,
                    notifyUser: t["notify_user"] as? Bool ?? false,
                    provider: t["provider"] as? String ?? "anthropic",
                    modelId: t["model_id"] as? String
                        ?? ProviderConfig.defaultModels[t["provider"] as? String ?? "anthropic"]
                        ?? ""
                )
            }

            await MainActor.run {
                self.scheduledTasks = parsed
            }
        }
    }

    func toggleScheduledTask(_ taskId: String, enabled: Bool) {
        if let idx = scheduledTasks.firstIndex(where: { $0.id == taskId }) {
            scheduledTasks[idx].enabled = enabled
        }
        Task {
            if (try? await daemonConnection.request(
                "/v1/scheduled/\(taskId)",
                method: "PATCH",
                json: ["enabled": enabled]
            )) == nil {
                await MainActor.run { self.loadScheduledTasks() }
            }
        }
    }

    func deleteScheduledTask(_ taskId: String) {
        scheduledTasks.removeAll { $0.id == taskId }
        Task {
            if (try? await daemonConnection.request(
                "/v1/scheduled/\(taskId)",
                method: "DELETE"
            )) == nil {
                await MainActor.run { self.loadScheduledTasks() }
            }
        }
    }

    func createScheduledTask(_ draft: ScheduledTaskDraft) {
        saveScheduledTask(nil, draft: draft)
    }

    func updateScheduledTask(_ id: String, draft: ScheduledTaskDraft) {
        saveScheduledTask(id, draft: draft)
    }

    private func saveScheduledTask(_ id: String?, draft: ScheduledTaskDraft) {
        scheduledTaskError = nil
        Task {
            do {
                _ = try await daemonConnection.request(
                    id.map { "/v1/scheduled/\($0)" } ?? "/v1/scheduled",
                    method: id == nil ? "POST" : "PATCH",
                    json: [
                        "name": draft.name,
                        "prompt": draft.prompt,
                        "task_type": "scheduled",
                        "cron": draft.cron,
                        "notify_user": draft.notifyUser,
                        "provider": draft.provider,
                        "model_id": draft.modelId,
                    ]
                )
                await MainActor.run { self.loadScheduledTasks() }
            } catch {
                await MainActor.run { self.scheduledTaskError = error.localizedDescription }
            }
        }
    }

    func runScheduledTaskNow(_ id: String) {
        Task {
            do {
                _ = try await daemonConnection.request(
                    "/v1/scheduled/\(id)/run",
                    method: "POST",
                    json: [:]
                )
                await MainActor.run { self.loadScheduledTasks() }
            } catch {
                await MainActor.run { self.scheduledTaskError = error.localizedDescription }
            }
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


    // MARK: - Local Daemon Configuration

    func checkAppStatus(_ appType: String) {
        appLoading[appType] = true
        appError[appType] = nil
        Task {
            do {
                let data = try await daemonConnection.request("/v1/integrations/\(appType)")
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                await MainActor.run {
                    self.appConnected[appType] = json?["connected"] as? Bool ?? false
                    self.appConnectionStatus[appType] =
                        json?["status"] as? String ?? "disconnected"
                    self.appLoading[appType] = false
                }
            } catch {
                await MainActor.run {
                    self.appError[appType] = error.localizedDescription
                    self.appConnectionStatus[appType] = "error"
                    self.appLoading[appType] = false
                }
            }
        }
    }

    func connectApp(_ appType: String) {
        appLoading[appType] = true
        appError[appType] = nil
        Task {
            do {
                let data = try await daemonConnection.request(
                    "/v1/integrations/\(appType)/connect",
                    method: "POST",
                    json: [:]
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                if json?["connected"] as? Bool == true {
                    await MainActor.run {
                        self.appConnected[appType] = true
                        self.appConnectionStatus[appType] =
                            json?["status"] as? String ?? "ACTIVE"
                        self.appLoading[appType] = false
                    }
                    return
                }
                if let value = (json?["redirect_url"] ?? json?["redirectUrl"]) as? String,
                   let url = URL(string: value),
                   url.scheme?.lowercased() == "https",
                   url.host != nil {
                    await MainActor.run {
                        self.appConnectionStatus[appType] = "pending"
                        self.appLoading[appType] = false
                    }
                    _ = await MainActor.run { NSWorkspace.shared.open(url) }
                }
                for _ in 0..<40 {
                    try await Task.sleep(for: .seconds(3))
                    let status = try await daemonConnection.request("/v1/integrations/\(appType)")
                    let payload = try JSONSerialization.jsonObject(with: status) as? [String: Any]
                    if payload?["connected"] as? Bool == true {
                        await MainActor.run {
                            self.appConnected[appType] = true
                            self.appConnectionStatus[appType] = "ACTIVE"
                            self.appLoading[appType] = false
                        }
                        return
                    }
                }
                await MainActor.run {
                    self.appError[appType] = "Connection timed out."
                    self.appConnectionStatus[appType] = "error"
                    self.appLoading[appType] = false
                }
            } catch {
                await MainActor.run {
                    self.appError[appType] = error.localizedDescription
                    self.appConnectionStatus[appType] = "error"
                    self.appLoading[appType] = false
                }
            }
        }
    }

    func disconnectApp(_ appType: String) {
        appLoading[appType] = true
        Task {
            do {
                _ = try await daemonConnection.request(
                    "/v1/integrations/\(appType)/disconnect",
                    method: "POST",
                    json: [:]
                )
                await MainActor.run {
                    self.appConnected[appType] = false
                    self.appConnectionStatus[appType] = "disconnected"
                    self.appLoading[appType] = false
                }
            } catch {
                await MainActor.run {
                    self.appError[appType] = error.localizedDescription
                    self.appConnectionStatus[appType] = "error"
                    self.appLoading[appType] = false
                }
            }
        }
    }

    func resetApp(_ appType: String) {
        appError[appType] = nil
        appLoading[appType] = false
        if appConnected[appType] != true {
            appConnectionStatus[appType] = "disconnected"
        }
    }

    func configureComposio(
        apiKey: String? = nil,
        authConfigIDs: [String: String] = [:]
    ) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key?.isEmpty == false || !authConfigIDs.isEmpty else { return }
        appLoading["composio"] = true
        appError["composio"] = nil
        Task {
            do {
                var body: [String: Any] = [:]
                if let key, !key.isEmpty { body["api_key"] = key }
                if !authConfigIDs.isEmpty { body["auth_config_ids"] = authConfigIDs }
                let data = try await daemonConnection.request(
                    "/v1/config/composio",
                    method: "PUT",
                    json: body
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                await MainActor.run {
                    self.composioState = ComposioConfigState.parse(json)
                    self.synchronizeComposioConnections(preservePending: false)
                    self.appLoading["composio"] = false
                }
            } catch {
                await MainActor.run {
                    self.appError["composio"] = error.localizedDescription
                    self.appLoading["composio"] = false
                }
            }
        }
    }

    func loadComposioState() {
        Task {
            guard let data = try? await daemonConnection.request("/v1/config/composio"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            await MainActor.run {
                self.composioState = ComposioConfigState.parse(json)
                self.synchronizeComposioConnections()
            }
        }
    }

    private func synchronizeComposioConnections(preservePending: Bool = true) {
        for integration in composioState.integrations {
            let connected = composioState.connectedApps.contains(integration.appType)
            appConnected[integration.appType] = connected
            if connected {
                appConnectionStatus[integration.appType] = "ACTIVE"
            } else if !preservePending
                        || appConnectionStatus[integration.appType]?.lowercased() != "pending" {
                appConnectionStatus[integration.appType] = "disconnected"
            }
        }
    }

    func loadProviderConfigs(completion: (([ProviderConfig]) -> Void)? = nil) {
        providerLoading = true
        Task {
            do {
                let data = try await daemonConnection.request("/v1/config/providers")
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let configs = json?["providers"] as? [[String: Any]] ?? []
                let parsed = configs.compactMap { value -> ProviderConfig? in
                    guard let rawProvider = value["provider"] as? String,
                          let model = value["model_id"] as? String else { return nil }
                    let provider = rawProvider == "custom_openai" ? "custom" : rawProvider
                    return ProviderConfig(
                        id: value["id"] as? String ?? provider,
                        provider: provider,
                        modelId: model,
                        isActive: value["is_active"] as? Bool ?? false,
                        verifiedAt: value["verified_at"] as? String,
                        baseURL: value["base_url"] as? String
                    )
                }
                await MainActor.run {
                    self.providerConfigs = parsed
                    self.providerLoading = false
                    if let active = parsed.first(where: \.isActive) {
                        self.activeModelProvider = active.provider
                        self.settings.selectedDefaultModel = active.modelId
                    }
                    completion?(parsed)
                    self.loadProviderModels()
                }
            } catch {
                await MainActor.run { self.providerLoading = false }
            }
        }
    }

    func loadProviderModels() {
        let provider = activeProviderType
        activeModelProvider = provider
        modelOptions = fallbackModelOptions(for: provider)
        ensureSelectedModelIsAvailable(activeModel: providerConfigs.first(where: \.isActive)?.modelId)
        isLoadingModels = true
        Task {
            defer { Task { @MainActor in self.isLoadingModels = false } }
            guard let data = try? await daemonConnection.request("/v1/config/providers/models"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let rawRemoteProvider = json["provider"] as? String ?? provider
            let remoteProvider = rawRemoteProvider == "custom_openai" ? "custom" : rawRemoteProvider
            let models: [ProviderModelOption] = (json["models"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["id"] as? String else { return nil }
                return ProviderModelOption(
                    id: id,
                    name: $0["name"] as? String ?? id,
                    provider: remoteProvider,
                    contextLength: $0["context_length"] as? Int
                )
            }
            await MainActor.run {
                if !models.isEmpty { self.modelOptions = models }
                self.activeModelProvider = remoteProvider
                self.ensureSelectedModelIsAvailable(activeModel: json["active_model"] as? String)
            }
        }
    }

    func selectModel(_ modelId: String) {
        guard !modelId.isEmpty else { return }
        settings.selectedDefaultModel = modelId
    }

    private func selectedModelIdForRequest() -> String {
        let configured = settings.selectedDefaultModel
        if !configured.isEmpty { return configured }
        return providerConfigs.first(where: \.isActive)?.modelId
            ?? ProviderConfig.defaultModels[activeProviderType]
            ?? ""
    }

    var activeProviderType: String {
        providerConfigs.first(where: \.isActive)?.provider ?? "anthropic"
    }

    private func ensureSelectedModelIsAvailable(activeModel: String?) {
        if let activeModel, !activeModel.isEmpty {
            settings.selectedDefaultModel = activeModel
        } else if settings.selectedDefaultModel.isEmpty {
            settings.selectedDefaultModel = modelOptions.first?.id
                ?? ProviderConfig.defaultModels[activeProviderType]
                ?? ""
        }
    }

    private func fallbackModelOptions(for provider: String) -> [ProviderModelOption] {
        let configured = providerConfigs.first { $0.provider == provider }?.modelId
        var values = ProviderConfig.availableModels[provider] ?? []
        if let configured, !configured.isEmpty, !values.contains(where: { $0.id == configured }) {
            values.insert((configured, configured), at: 0)
        }
        return values.map {
            ProviderModelOption(id: $0.id, name: $0.label, provider: provider, contextLength: nil)
        }
    }

    func verifyProviderKey(
        provider: String,
        apiKey: String,
        modelId: String,
        baseURL: String? = nil
    ) {
        providerVerifying[provider] = true
        providerVerified[provider] = false
        providerError[provider] = nil
        Task {
            do {
                var body: [String: Any] = [
                    "provider": provider,
                    "api_key": apiKey,
                    "model_id": modelId,
                ]
                if let baseURL { body["base_url"] = baseURL }
                let data = try await daemonConnection.request(
                    "/v1/config/providers/verify",
                    method: "POST",
                    json: body
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let verified = json?["verified"] as? Bool == true
                await MainActor.run {
                    self.providerVerifying[provider] = false
                    self.providerVerified[provider] = verified
                    self.providerError[provider] = verified
                        ? nil
                        : (json?["error"] as? String ?? "Verification failed")
                }
            } catch {
                await MainActor.run {
                    self.providerVerifying[provider] = false
                    self.providerError[provider] = error.localizedDescription
                }
            }
        }
    }

    func saveProviderConfig(
        provider: String,
        apiKey: String,
        modelId: String,
        baseURL: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !apiKey.isEmpty else {
            completion?(false)
            return
        }
        print("[Perch] Provider save started: \(provider)")
        Task {
            do {
                var body: [String: Any] = [
                    "provider": provider,
                    "api_key": apiKey,
                    "model_id": modelId,
                ]
                if let baseURL { body["base_url"] = baseURL }
                let data = try await daemonConnection.request(
                    "/v1/config/providers",
                    method: "PUT",
                    json: body
                )
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let saved = json?["saved"] as? Bool == true
                await MainActor.run {
                    if saved {
                        self.activeModelProvider = provider
                        self.settings.selectedDefaultModel = modelId
                    }
                    print("[Perch] Provider save completed: \(provider), saved=\(saved)")
                    self.loadProviderConfigs()
                    completion?(saved)
                }
            } catch {
                await MainActor.run {
                    print("[Perch] Provider save failed: \(provider): \(error.localizedDescription)")
                    self.providerError[provider] = error.localizedDescription
                    completion?(false)
                }
            }
        }
    }

    func activateProviderConfig(provider: String) {
        Task {
            do {
                _ = try await daemonConnection.request(
                    "/v1/config/providers/activate",
                    method: "POST",
                    json: ["provider": provider]
                )
                await MainActor.run { self.loadProviderConfigs() }
            } catch {
                await MainActor.run { self.providerError[provider] = error.localizedDescription }
            }
        }
    }

    func deleteProviderConfig(provider: String) {
        Task {
            do {
                _ = try await daemonConnection.request(
                    "/v1/config/providers/\(provider)",
                    method: "DELETE"
                )
                await MainActor.run {
                    self.providerConfigs.removeAll { $0.provider == provider }
                    self.loadProviderModels()
                }
            } catch {
                await MainActor.run { self.providerError[provider] = error.localizedDescription }
            }
        }
    }

    // MARK: - Event Processing

    func processEvent(_ json: [String: Any]) {
        guard installationID != nil else { return }
        guard let type = json["type"] as? String else { return }
        switch type {
        case "subagent_event": processSubagentEvent(json)
        case "task_summary": processBulkUpdate(json)
        case "scheduled_task_update":
            loadScheduledTasks()
        case "notification": processNotification(json)
        case "peek_notification": processPeekNotification(json)
        case "connection_request": processConnectionRequest(json)
        case "pending_action": processPendingAction(json)
        case "local_action_offered": processLocalActionOffer(json)
        case "local_execution_request": processLocalExecutionRequest(json)
        default: break
        }
    }

    private func processLocalActionOffer(_ json: [String: Any]) {
        guard let actionID = json["action_id"] as? String,
              UUID(uuidString: actionID) != nil,
              let sessionID = (json["session_id"] ?? json["run_id"]) as? String,
              let registryVersion = json["registry_version"] as? String,
              let actionType = json["action_type"] as? String,
              let actionHash = json["action_hash"] as? String,
              let parametersHash = json["parameters_hash"] as? String,
              let parametersValue = json["normalized_parameters"],
              let capabilitiesValue = json["capabilities"],
              let workspaceBookmarkID = json["workspace_bookmark_id"] as? String,
              let expiresValue = json["expires_at"] as? String,
              let expiresAt = ISO8601DateFormatter().date(from: expiresValue),
              let taskIndex = tasks.firstIndex(where: {
                  $0.id == sessionID || $0.threadId == sessionID
              }),
              !tasks[taskIndex].chatHistory.contains(where: { $0.id == actionID }),
              let parametersJSON = try? JSONSerialization.data(
                  withJSONObject: parametersValue,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let capabilitiesJSON = try? JSONSerialization.data(
                  withJSONObject: capabilitiesValue,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let parameters = try? ExecutorJSON(any: parametersValue),
              let capabilities = try? ExecutionCapabilities(
                  json: ExecutorJSON(any: capabilitiesValue)
              ),
              let action = try? LocalActionRegistry.shared.resolve(
                  registryVersion: registryVersion,
                  name: actionType,
                  parameters: parameters,
                  capabilities: capabilities
              ) else {
            return
        }
        let networkUnavailable = !capabilities.egressDestinations.isEmpty
        let executorUnavailable = executorUnavailableReason
        let unavailable = networkUnavailable || executorUnavailable != nil
        let card = LocalExecutionConsentCard(
            actionID: actionID.lowercased(),
            registryVersion: registryVersion,
            actionType: actionType,
            actionHash: actionHash,
            parametersHash: parametersHash,
            normalizedParametersJSON: parametersJSON,
            capabilitiesJSON: capabilitiesJSON,
            workspaceBookmarkID: workspaceBookmarkID,
            command: [action.executable] + action.arguments,
            workspaceMode: capabilities.workspaceMode.rawValue,
            egressDestinations: capabilities.egressDestinations,
            sensitiveFileAccess: capabilities.sensitiveFileAccess,
            sensitiveDisclosure: capabilities.sensitiveOutputDisclosure,
            resultUpload: capabilities.resultUpload,
            expiresAt: expiresAt,
            expiresAtValue: expiresValue,
            selectedWorkspacePath: nil,
            confirmations: [],
            state: unavailable ? .unavailable : .pending,
            error: networkUnavailable
                ? "Network access is unavailable; this executor always runs offline."
                : executorUnavailable
        )
        tasks[taskIndex].chatHistory.append(ChatMessage(
            id: actionID,
            role: "local_execution_consent",
            content: action.displayName,
            localExecutionCard: card,
            timestamp: Date()
        ))
        tasks[taskIndex].status = .awaitingApproval
        persistTask(at: taskIndex)
    }

    private var executorUnavailableReason: String? {
        switch executionBackend.capabilityState {
        case .available:
            return nil
        case .unsupportedOS:
            return "Local VM execution requires macOS 26 or newer."
        case .unsupportedArchitecture:
            return "Local VM execution requires Apple silicon."
        case .artifactsUnavailable:
            return "The signed executor or its pinned VM artifacts are not verified."
        case .virtualizationUnavailable:
            return "The signed executor does not have the required virtualization entitlement."
        }
    }

    func chooseExecutionWorkspace(actionID: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Select Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedExecutionWorkspaces[actionID] = url
        updateLocalConsent(actionID) {
            LocalConsentCardReducer().reduce($0, event: .selectedWorkspace(url.path))
        }
    }

    func toggleExecutionConfirmation(
        actionID: String,
        confirmation: LocalConsentConfirmation
    ) {
        updateLocalConsent(actionID) {
            LocalConsentCardReducer().reduce($0, event: .toggled(confirmation))
        }
    }

    func approveLocalExecution(actionID: String) {
        guard let workspace = selectedExecutionWorkspaces[actionID],
              let installationID,
              UUID(uuidString: installationID) != nil else { return }
        updateLocalConsent(actionID) {
            LocalConsentCardReducer().reduce($0, event: .approve)
        }
        guard let card = localConsentCard(actionID),
              card.state == .approving,
              let actionUUID = UUID(uuidString: card.actionID) else { return }
        Task {
            do {
                let bookmark = try workspaceBookmarkResolver.create(for: workspace)
                try await workspaceBookmarks.save(
                    bookmark.data,
                    identifier: card.workspaceBookmarkID,
                    userID: installationID
                )
                let identity = try deviceIdentities.identity(
                    for: installationID,
                    createIfMissing: true
                )
                let fingerprint = try ExecutorIPCAuthenticator.fingerprint(
                    publicKeyPEM: identity.publicKey.value
                )
                let imageDigest = try executorInstallation
                    .verifiedInstallation()
                    .workloadImageDigest
                try await daemonConnection.approveLocalAction(
                    actionID: actionUUID,
                    actionHash: card.actionHash,
                    parametersHash: card.parametersHash,
                    workspaceURL: workspace,
                    workspaceBookmarkID: card.workspaceBookmarkID,
                    highRiskShell: card.actionType == "shell.execute",
                    expiresAt: card.expiresAtValue
                        ?? ISO8601DateFormatter().string(from: card.expiresAt),
                    deviceID: installationID,
                    deviceKeyFingerprint: fingerprint,
                    imageDigest: imageDigest
                )
                await MainActor.run {
                    self.updateLocalConsent(actionID) {
                        LocalConsentCardReducer().reduce($0, event: .approved)
                    }
                }
            } catch {
                await MainActor.run {
                    self.updateLocalConsent(actionID) {
                        LocalConsentCardReducer().reduce(
                            $0,
                            event: .failed(error.localizedDescription)
                        )
                    }
                }
            }
        }
    }

    func rejectLocalExecution(actionID: String) {
        guard let card = localConsentCard(actionID),
              let actionUUID = UUID(uuidString: card.actionID) else { return }
        updateLocalConsent(actionID) {
            LocalConsentCardReducer().reduce($0, event: .reject)
        }
        Task {
            try? await daemonConnection.rejectLocalAction(
                actionID: actionUUID,
                actionHash: card.actionHash,
                parametersHash: card.parametersHash,
                workspaceBookmarkID: card.workspaceBookmarkID,
                expiresAt: card.expiresAtValue
                    ?? ISO8601DateFormatter().string(from: card.expiresAt)
            )
        }
    }

    private func processLocalExecutionRequest(_ json: [String: Any]) {
        guard let installationID else { return }
        Task {
            do {
                guard let response = try await executionRequests.handle(
                    event: json,
                    installationID: installationID
                ) else { return }
                try await daemonConnection.send(type: "execution_result", payload: response)
            } catch {
                // Malformed requests have no trustworthy correlation IDs and
                // therefore cannot safely receive a terminal response.
            }
        }
    }

    private func localConsentCard(_ actionID: String) -> LocalExecutionConsentCard? {
        for task in tasks {
            if let message = task.chatHistory.first(where: { $0.id == actionID }) {
                return message.localExecutionCard
            }
        }
        return nil
    }

    private func updateLocalConsent(
        _ actionID: String,
        transform: (LocalExecutionConsentCard) -> LocalExecutionConsentCard
    ) {
        for taskIndex in tasks.indices {
            guard let messageIndex = tasks[taskIndex].chatHistory.firstIndex(
                where: { $0.id == actionID }
            ), let card = tasks[taskIndex].chatHistory[messageIndex].localExecutionCard else {
                continue
            }
            tasks[taskIndex].chatHistory[messageIndex].localExecutionCard = transform(card)
            persistTask(at: taskIndex)
            return
        }
    }

    private func processPendingAction(_ json: [String: Any]) {
        guard let actionId = json["action_id"] as? String,
              let sessionId = json["session_id"] as? String,
              let actionType = json["action_type"] as? String,
              let summary = json["summary"] as? String else { return }

        guard let idx = tasks.firstIndex(where: { $0.id == sessionId }) else { return }
        // Skip if we already have this action's card (dedupe re-delivery).
        if tasks[idx].chatHistory.contains(where: { $0.id == actionId }) { return }

        let card = DraftCard(
            type: actionType,
            title: summary,
            preview: "This action needs your approval before it runs.",
            recipient: nil
        )
        withAnimation(.snappy(duration: 0.3)) {
            tasks[idx].chatHistory.append(ChatMessage(
                id: actionId, role: "draft",
                content: summary, toolName: actionType,
                toolInput: nil, toolOutput: "pending",
                draftCard: card, timestamp: Date()
            ))
        }
        persistTask(at: idx)
    }

    func approveDraftAction(_ actionId: String) {
        updateDraftActionStatus(actionId, status: "executing")
        performDraftDecision(actionId, path: "approve")
    }

    func rejectDraftAction(_ actionId: String) {
        updateDraftActionStatus(actionId, status: "rejected")
        performDraftDecision(actionId, path: "reject")
    }

    private func performDraftDecision(_ actionId: String, path: String) {
        Task {
            let succeeded = (try? await daemonConnection.request(
                "/v1/actions/\(actionId)/\(path)",
                method: "POST",
                json: [:]
            )) != nil
            await MainActor.run {
                if path == "approve" {
                    self.updateDraftActionStatus(actionId, status: succeeded ? "completed" : "failed")
                } else {
                    self.updateDraftActionStatus(actionId, status: succeeded ? "rejected" : "pending")
                }
            }
        }
    }

    private func updateDraftActionStatus(_ actionId: String, status: String) {
        for taskIdx in tasks.indices {
            if let msgIdx = tasks[taskIdx].chatHistory.firstIndex(where: { $0.id == actionId }) {
                withAnimation(.snappy(duration: 0.2)) {
                    tasks[taskIdx].chatHistory[msgIdx].toolOutput = status
                }
                persistTask(at: taskIdx)
                return
            }
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

        Task {
            try? await daemonConnection.send(
                type: "connection_response",
                payload: ["request_id": requestId, "approved": true]
            )
        }

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
                    }
                    return
                }
            }

            // Timed out waiting for connection
            await MainActor.run {
                self.pendingConnectionRequests[requestId]?.status = .denied
                self.updateConnectionRequestMessage(requestId, status: .denied)
            }
        }
    }

    func denyConnectionRequest(_ requestId: String) {
        guard var request = pendingConnectionRequests[requestId] else { return }
        request.status = .denied
        pendingConnectionRequests[requestId] = request

        updateConnectionRequestMessage(requestId, status: .denied)
        Task {
            try? await daemonConnection.send(
                type: "connection_response",
                payload: ["request_id": requestId, "approved": false]
            )
        }
    }

    private func updateConnectionRequestMessage(_ requestId: String, status: ConnectionRequestStatus) {
        guard let request = pendingConnectionRequests[requestId],
              let taskIdx = tasks.firstIndex(where: { $0.id == request.sessionId }),
              let msgIdx = tasks[taskIdx].chatHistory.firstIndex(where: { $0.id == requestId }) else { return }

        withAnimation(.snappy(duration: 0.2)) {
            // Store the status in toolOutput so the UI can read it
            tasks[taskIdx].chatHistory[msgIdx].toolOutput = status.rawValue
        }
        // Persist so a resolved (approved/denied) request survives app restart
        // instead of reappearing as a dangling pending card.
        persistTask(at: taskIdx)
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
                // Perch runs indefinitely in the background; without a cap this
                // array (and unreadCount below) would grow forever as
                // peek_notification events arrive over weeks/months. Full
                // history is still fetchable from the backend via
                // loadNotifications(); this only bounds the in-memory list fed
                // by live WebSocket pushes.
                let maxNotifications = 200
                if notifications.count > maxNotifications {
                    notifications.removeLast(notifications.count - maxNotifications)
                }
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

        if settings.systemNotificationsEnabled, Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = String(Self.cleanNotifBody(body).prefix(500))
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
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
        let pinnedProvider: String
        let pinnedModel: String
        if let existing = tasks.first(where: { $0.id == sid }) {
            pinnedProvider = existing.provider ?? activeProviderType
            pinnedModel = existing.modelId ?? selectedModelIdForRequest()
        } else {
            pinnedProvider = activeProviderType
            pinnedModel = selectedModelIdForRequest()
        }

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
                    tasks[idx].provider = pinnedProvider
                    tasks[idx].modelId = pinnedModel
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
                threadId: sid,
                provider: pinnedProvider,
                modelId: pinnedModel
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

        let historyForRequest = recentHistoryPayload(for: sid, currentMessage: message)
        Task {
            do {
                let data = try await daemonConnection.request(
                    "/v1/chat",
                    method: "POST",
                    json: [
                        "message": message,
                        "session_id": sid,
                        "conversation_id": sid,
                        "provider": pinnedProvider,
                        "model_id": pinnedModel,
                        "history": historyForRequest,
                    ]
                )
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                await MainActor.run {
                    guard let idx = self.tasks.firstIndex(where: { $0.id == sid }) else { return }
                    if let response = json, let threadId = response["thread_id"] as? String {
                        self.tasks[idx].threadId = threadId
                        self.persistTask(at: idx)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let idx = self.tasks.firstIndex(where: { $0.id == sid }) else { return }
                    withAnimation(.snappy(duration: 0.3)) {
                        self.tasks[idx].status = .failed
                        self.tasks[idx].error = error.localizedDescription
                    }
                    self.persistTask(at: idx)
                }
            }
        }
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
