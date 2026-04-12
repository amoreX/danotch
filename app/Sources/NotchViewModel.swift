import Foundation
import SwiftUI
import Combine

enum MusicSize: String, CaseIterable {
    case mini = "mini"
    case big = "big"
    var label: String { self == .mini ? "MINI" : "BIG" }
}

enum MusicSource: String, CaseIterable {
    case auto        = "auto"
    case spotify     = "spotify"
    case appleMusic  = "appleMusic"
    var label: String {
        switch self {
        case .auto:       return "Auto"
        case .spotify:    return "Spotify"
        case .appleMusic: return "Apple Music"
        }
    }
}

// MARK: - Widget Grid Types

enum WidgetSize: String, Codable, CaseIterable {
    case small   // 1 col × 1 row  ≈ 173 × 80
    case medium  // 2 col × 1 row  ≈ 352 × 80
    case wide    // 3 col × 1 row  ≈ 532 × 80
    case large   // 2 col × 2 rows ≈ 352 × 166

    var colSpan: Int {
        switch self {
        case .small: return 1
        case .medium, .large: return 2
        case .wide: return 3
        }
    }
    var rowSpan: Int { self == .large ? 2 : 1 }
    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .large: return "Large"
        }
    }
}

struct WidgetSlot: Identifiable, Codable {
    var id: String = UUID().uuidString
    var type: PinnedWidget
    var size: WidgetSize
}

enum PinnedWidget: String, CaseIterable, Codable {
    case clock      = "clock"
    case music      = "music"
    case calendar   = "calendar"
    case cpu        = "cpu"
    case battery    = "battery"
    case agentCount = "agentCount"
    case ram        = "ram"
    case disk       = "disk"
    case network    = "network"
    case uptime     = "uptime"
    case processes  = "processes"

    var label: String {
        switch self {
        case .clock:      return "Clock"
        case .music:      return "Music Player"
        case .calendar:   return "Calendar"
        case .cpu:        return "CPU Usage"
        case .battery:    return "Battery"
        case .agentCount: return "AI Agents"
        case .ram:        return "RAM Usage"
        case .disk:       return "Disk Usage"
        case .network:    return "Network"
        case .uptime:     return "Uptime"
        case .processes:  return "Processes"
        }
    }

    var icon: String {
        switch self {
        case .clock:      return "clock.fill"
        case .music:      return "music.note"
        case .calendar:   return "calendar"
        case .cpu:        return "cpu"
        case .battery:    return "battery.75percent"
        case .agentCount: return "laptopcomputer"
        case .ram:        return "memorychip"
        case .disk:       return "internaldrive"
        case .network:    return "network"
        case .uptime:     return "clock"
        case .processes:  return "list.number"
        }
    }

    var defaultSize: WidgetSize {
        switch self {
        case .clock:    return .wide
        case .music:    return .medium
        case .calendar: return .large
        default:        return .small
        }
    }

    var minHeight: CGFloat {
        switch self {
        case .calendar: return 62
        default:        return 80
        }
    }
}

class NotchSettings: ObservableObject {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".danotch")
    private static let configFile = configDir.appendingPathComponent("settings.json")

    // Chat behavior
    @Published var openChatOnSend: Bool         { didSet { save() } }
    @Published var restoreLastView: Bool        { didSet { save() } }
    @Published var keepOpenInChat: Bool         { didSet { save() } }

    // Widget grid
    @Published var widgetSlots: [WidgetSlot] {
        didSet {
            // Recalculate notch height whenever slots change
            let h = Self.calcExpandedHeight(for: widgetSlots)
            if abs(notchExpandedHeight - h) > 1 { notchExpandedHeight = h }
            save()
        }
    }
    @Published var notchExpandedHeight: CGFloat { didSet { save() } }
    @Published var showBattery: Bool            { didSet { save() } }
    @Published var showDotGrid: Bool            { didSet { save() } }

    // Agents
    @Published var showAgentLiveState: Bool     { didSet { save() } }
    @Published var compactAgentRows: Bool       { didSet { save() } }

    // Music source
    @Published var musicSource: MusicSource     { didSet { save() } }

    // Dot grid
    @Published var dotGridColor: String         { didSet { save() } }
    @Published var dotGridOpacity: Double       { didSet { save() } }

    var dotGridSwiftColor: Color {
        Color(hex: UInt32(dotGridColor.dropFirst(), radix: 16) ?? 0xFFFFFF)
    }

    // Compat helpers derived from widgetSlots
    var showMusic: Bool { widgetSlots.contains { $0.type == .music } }
    var musicSize: MusicSize {
        widgetSlots.first { $0.type == .music }.map { $0.size == .small ? .mini : .big } ?? .big
    }

    // Calculate the notch expanded height based on active widget slots
    static func calcExpandedHeight(for slots: [WidgetSlot]) -> CGFloat {
        guard !slots.isEmpty else { return 240 }
        let totalH = slots.map { $0.type.minHeight }.reduce(0, +)
        let gaps = CGFloat(max(0, slots.count - 1)) * 6
        return max(200, totalH + gaps + 8)
    }

    // UI state (persisted across restarts)
    @Published var collapsedGroups: Set<String> { didSet { save() } }

    private static var defaultSlots: [WidgetSlot] {
        [
            WidgetSlot(type: .clock,    size: .wide),
            WidgetSlot(type: .music,    size: .medium),
            WidgetSlot(type: .cpu,      size: .small),
            WidgetSlot(type: .calendar, size: .large),
            WidgetSlot(type: .battery,  size: .small),
        ]
    }

    init() {
        openChatOnSend      = true
        restoreLastView     = false
        keepOpenInChat      = true
        widgetSlots         = Self.defaultSlots
        notchExpandedHeight = Self.calcExpandedHeight(for: Self.defaultSlots)
        showBattery         = true
        showDotGrid         = true
        showAgentLiveState = true
        compactAgentRows   = false
        musicSource     = .auto
        dotGridColor    = "#00E5A0"
        dotGridOpacity  = 0.35
        collapsedGroups = []
        load()
    }

    private func save() {
        var data: [String: Any] = [
            "openChatOnSend":       openChatOnSend,
            "keepOpenInChat":       keepOpenInChat,
            "restoreLastView":      restoreLastView,
            "showBattery":          showBattery,
            "showDotGrid":          showDotGrid,
            "showAgentLiveState":   showAgentLiveState,
            "compactAgentRows":     compactAgentRows,
            "musicSource":          musicSource.rawValue,
            "dotGridColor":         dotGridColor,
            "dotGridOpacity":       dotGridOpacity,
            "collapsedGroups":      Array(collapsedGroups),
            "notchExpandedHeight":  Double(notchExpandedHeight),
        ]
        if let slotsData = try? JSONEncoder().encode(widgetSlots),
           let slotsObj = try? JSONSerialization.jsonObject(with: slotsData) {
            data["widgetSlots"] = slotsObj
        }
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: Self.configFile)
        } catch {}
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let v = json["openChatOnSend"]     as? Bool { openChatOnSend     = v }
        if let v = json["keepOpenInChat"]     as? Bool { keepOpenInChat     = v }
        if let v = json["restoreLastView"]    as? Bool { restoreLastView    = v }
        if let v = json["showBattery"]        as? Bool { showBattery        = v }
        if let v = json["showDotGrid"]        as? Bool { showDotGrid        = v }
        if let v = json["showAgentLiveState"] as? Bool { showAgentLiveState = v }
        if let v = json["compactAgentRows"]   as? Bool { compactAgentRows   = v }
        if let v = json["musicSource"]         as? String, let src = MusicSource(rawValue: v) { musicSource = src }
        if let v = json["dotGridColor"]       as? String { dotGridColor     = v }
        if let v = json["dotGridOpacity"]       as? Double { dotGridOpacity       = v }
        if let v = json["collapsedGroups"]      as? [String] { collapsedGroups = Set(v) }
        if let v = json["notchExpandedHeight"]  as? Double { notchExpandedHeight = CGFloat(v) }

        if let slotsObj = json["widgetSlots"],
           let slotsData = try? JSONSerialization.data(withJSONObject: slotsObj),
           let slots = try? JSONDecoder().decode([WidgetSlot].self, from: slotsData) {
            widgetSlots = slots
        } else if let pw = json["pinnedWidgets"] as? [String] {
            // Migrate from old format — always prepend clock widget
            var slots: [WidgetSlot] = [WidgetSlot(type: .clock, size: .wide)]
            for raw in pw {
                if let t = PinnedWidget(rawValue: raw), t != .clock {
                    slots.append(WidgetSlot(type: t, size: t.defaultSize))
                }
            }
            widgetSlots = slots
        }
    }
}

private enum APIConfig {
    static let baseURL = "http://localhost:3001"
}

private enum CachedFormatters {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm"; return f }()
    static let period: DateFormatter = { let f = DateFormatter(); f.dateFormat = "a"; return f }()
    static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"; return f }()
    static let shortDate: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
    static let shortTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()
}

enum NotchSizeState: Equatable {
    case collapsed, nudging, expanded
}

class NotchViewModel: ObservableObject {
    @Published var tasks: [SubagentTask] = []
    @Published var currentTime: Date = Date()
    @Published var viewState: NotchViewState = .overview
    @Published var notchSize: NotchSizeState = .collapsed
    @Published var shimmerStep: Int = 0
    @Published var isWidgetEditMode: Bool = false

    /// Convenience — rest of the app reads this
    var isExpanded: Bool {
        get { notchSize == .expanded }
        set { notchSize = newValue ? .expanded : .collapsed }
    }
    var isNudging: Bool { notchSize == .nudging }
    @Published var shouldFocusChatInput = false
    @Published var isChatInputActive = false
    var mouseInContent = false
    var lastViewBeforeCollapse: NotchViewState = .overview

    var authManager: AuthManager?
    @Published var isAuthenticated: Bool = AuthManager.shared.isAuthenticated

    // Gmail connection state
    @Published var gmailConnected = false
    @Published var gmailLoading = false

    @Published var settings = NotchSettings()
    @Published var agentMonitor = AgentMonitor()
    @Published var nowPlaying = NowPlayingMonitor()
    let statsMonitor = SystemStatsMonitor()
    let calendarEvents = CalendarEventsMonitor()
    let wallpaper = WallpaperColorMonitor()
    let batteryMonitor = BatteryMonitor()
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
        wallpaper.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        batteryMonitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Keep nowPlaying source in sync with settings
        settings.$musicSource.sink { [weak self] src in
            self?.nowPlaying.source = src
            self?.nowPlaying.poll()
        }.store(in: &cancellables)
        nowPlaying.source = settings.musicSource
        AuthManager.shared.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isAuthenticated = value
            }
            .store(in: &cancellables)
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

        var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/threads")!)
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

        var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/threads/\(threadId)")!)
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
                        displayRole = "agent"
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
                    threadId: threadId,
                    isFromHistory: true
                )

                withAnimation(.snappy(duration: 0.3)) {
                    self.tasks.insert(task, at: 0)
                    self.viewState = .agentChat(taskId)
                }
            }
        }.resume()
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
                    body: n["body"] as? String,
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
                print("[Danotch] loadScheduledTasks: failed status=\(status)")
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
                print("[Danotch] loadScheduledTasks: \(parsed.count) tasks")
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

    // MARK: - Gmail

    func checkGmailStatus() {
        guard let auth = authManager else { return }
        gmailLoading = true
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run { self.gmailLoading = false }
                return
            }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/gmail/status")!)
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connected = json["connected"] as? Bool else {
                await MainActor.run { self.gmailLoading = false }
                return
            }
            await MainActor.run {
                self.gmailConnected = connected
                self.gmailLoading = false
            }
        }
    }

    func connectGmail() {
        guard let auth = authManager else { return }
        gmailLoading = true
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run { self.gmailLoading = false }
                return
            }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/gmail/connect")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                await MainActor.run { self.gmailLoading = false }
                return
            }

            if json["already_connected"] as? Bool == true {
                await MainActor.run {
                    self.gmailConnected = true
                    self.gmailLoading = false
                }
                return
            }

            if let redirectUrl = json["redirectUrl"] as? String,
               let url = URL(string: redirectUrl) {
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                    self.gmailLoading = false
                }
                // Poll for connection after user completes OAuth
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.checkGmailStatus()
                return
            }

            // Auto-connected (no redirect needed)
            if json["connected"] as? Bool == true {
                await MainActor.run {
                    self.gmailConnected = true
                    self.gmailLoading = false
                }
                return
            }

            await MainActor.run { self.gmailLoading = false }
        }
    }

    func disconnectGmail() {
        guard let auth = authManager else { return }
        gmailLoading = true
        Task {
            await auth.ensureValidToken()
            guard let token = auth.accessToken else {
                await MainActor.run { self.gmailLoading = false }
                return
            }
            var request = URLRequest(url: URL(string: "\(APIConfig.baseURL)/api/gmail/disconnect")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            _ = try? await URLSession.shared.data(for: request)
            await MainActor.run {
                self.gmailConnected = false
                self.gmailLoading = false
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
            // If this is a title-only update (has "title" key), only update description
            if let title = data["title"] as? String {
                withAnimation(.easeOut(duration: 0.2)) {
                    tasks[idx].task = title
                    tasks[idx].description = title
                }
                return
            }
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

    private func processNotification(_ json: [String: Any]) {
        guard let data = json["data"] as? [String: Any],
              let id = data["id"] as? String,
              let title = data["title"] as? String else { return }

        let item = NotificationItem(
            id: id,
            title: title,
            body: data["body"] as? String,
            source: data["source"] as? String ?? "system",
            sourceId: data["source_id"] as? String,
            read: false,
            createdAt: data["created_at"] as? String ?? ""
        )

        withAnimation(.snappy(duration: 0.3)) {
            notifications.insert(item, at: 0)
            unreadCount += 1
        }

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

        let body = data["body"] as? String ?? ""

        let item = NotificationItem(
            id: id,
            title: title,
            body: body,
            source: data["source"] as? String ?? "system",
            sourceId: data["source_id"] as? String,
            read: false,
            createdAt: data["created_at"] as? String ?? ""
        )

        withAnimation(.snappy(duration: 0.3)) {
            notifications.insert(item, at: 0)
            unreadCount += 1
        }

        // Soft peek — don't fully expand, just grow the notch slightly
        withAnimation(.snappy(duration: 0.35)) {
            peekTitle = title
            peekBody = String(body.prefix(300))
            isPeeking = true
        }

        // Auto-dismiss after 4 seconds unless hovering
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.peekHovering else { return }
            self.dismissPeek()
        }

        loadScheduledTasks()
    }

    func dismissPeek() {
        withAnimation(.easeOut(duration: 0.25)) {
            isPeeking = false
            peekHovering = false
        }
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
            guard let url = URL(string: "\(APIConfig.baseURL)/api/chat") else { return }
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
