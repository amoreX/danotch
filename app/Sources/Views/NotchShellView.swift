import SwiftUI
import AppKit
import IOKit.ps

struct NotchShellView: View {
    @ObservedObject var viewModel: NotchViewModel

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    private var notchW: CGFloat { screen.notchWidth }
    private var notchH: CGFloat { screen.notchHeight }
    private var expanded: Bool { viewModel.isExpanded }

    private var shapeWidth: CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchW + 200 : notchW + 140
        }
        if !expanded { return notchW }
        switch viewModel.viewState {
        case .taskList, .agentChat: return 540
        case .processList: return 540
        case .stats: return 520
        case .settings: return 520
        case .notifications: return 520
        case .overview: return 520
        }
    }

    private var shapeHeight: CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchH + 80 : notchH + 28
        }
        if !expanded { return notchH }
        switch viewModel.viewState {
        case .overview: return notchH + 260
        case .taskList: return notchH + 260
        case .agentChat: return notchH + 320
        case .stats: return notchH + 290
        case .processList: return notchH + 320
        case .settings: return notchH + 320
        case .notifications: return notchH + 290
        }
    }

    private var bottomRadius: CGFloat {
        if viewModel.isPeeking { return 12 }
        return expanded ? 16 : 8
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape

            // Peek state — soft grow, just title + optional body on hover
            if viewModel.isPeeking {
                peekContent
                    .padding(.top, notchH)
                    .padding(.horizontal, DN.spaceSM)
                    .frame(width: shapeWidth, alignment: .top)
                    .transition(.opacity)
            }

            if expanded && !viewModel.isPeeking {
                // Interactive dot grid behind content
                if viewModel.settings.showDotGrid {
                    DotGridView(dotColor: viewModel.settings.dotGridSwiftColor)
                        .padding(.top, notchH)
                        .opacity(viewModel.settings.dotGridOpacity)
                        .allowsHitTesting(false)
                }

                expandedTopBar
                    .transition(.opacity)

                expandedContent
                    .padding(.top, notchH + 1)
                    .padding(.horizontal, DN.spaceMD)
                    .padding(.bottom, DN.spaceSM)
                    .frame(width: shapeWidth, alignment: .top)
            }
        }
        .frame(width: shapeWidth, height: shapeHeight)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
        )
        .onHover { hovering in
            viewModel.mouseInContent = hovering
            if viewModel.isPeeking {
                withAnimation(.easeOut(duration: 0.2)) {
                    viewModel.peekHovering = hovering
                }
                // If user stops hovering peek, dismiss after 2s
                if !hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak viewModel] in
                        guard let vm = viewModel, vm.isPeeking, !vm.peekHovering else { return }
                        vm.dismissPeek()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.35), value: expanded)
        .animation(.easeOut(duration: 0.25), value: viewModel.isPeeking)
        .animation(.easeOut(duration: 0.2), value: viewModel.peekHovering)
        .animation(.easeOut(duration: DN.transitionDuration), value: viewModel.viewState)
    }

    private var notchShape: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(DN.black)
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .stroke(expanded ? DN.border : .clear, lineWidth: 1)
        )
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        switch viewModel.viewState {
        case .overview, .taskList, .agentChat:
            NotchContentView(viewModel: viewModel)
        case .stats:
            StatsPanel(viewModel: viewModel)
        case .processList:
            ProcessListPanel(viewModel: viewModel)
        case .settings:
            SettingsPanel(viewModel: viewModel)
        case .notifications:
            NotificationsPanel(viewModel: viewModel)
        }
    }

    @ViewBuilder
    private var peekContent: some View {
        VStack(alignment: .leading, spacing: DN.spaceXS) {
            // Compact title line — always visible
            HStack(spacing: DN.spaceXS) {
                Text("❗")
                    .font(.system(size: 9))

                Text(viewModel.peekTitle)
                    .font(DN.body(10, weight: .semibold))
                    .foregroundColor(DN.textDisplay)
                    .lineLimit(1)
            }
            .padding(.horizontal, DN.spaceXS)
            .padding(.top, 4)

            // Body — only on hover
            if viewModel.peekHovering {
                MarkdownView(text: viewModel.peekBody, isFinal: true)
                    .padding(.horizontal, DN.spaceXS)
                    .transition(.opacity.combined(with: .move(edge: .top)))

                HStack {
                    Spacer()
                    Button(action: {
                        viewModel.dismissPeek()
                        withAnimation(DN.transition) {
                            viewModel.isExpanded = true
                            viewModel.viewState = .notifications
                        }
                    }) {
                        Text("VIEW ALL")
                            .font(DN.label(7))
                            .tracking(0.8)
                            .foregroundColor(DN.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DN.spaceXS)
            }
        }
    }

    // MARK: - Top Bar

    private var expandedTopBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: DN.spaceMD) {
                tabButton(
                    label: "HOME",
                    isActive: viewModel.viewState == .overview
                ) {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .overview
                    }
                }

                tabButton(
                    label: "AGENTS",
                    isActive: viewModel.isInTaskOrChat
                ) {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .taskList
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Color.clear.frame(width: notchW + DN.spaceMD)

            HStack(spacing: DN.spaceSM) {
                tabButton(
                    label: "STATS",
                    isActive: viewModel.viewState == .stats || viewModel.viewState == .processList
                ) {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .stats
                    }
                }

                // Bell icon
                let notifsActive = viewModel.viewState == .notifications
                Button(action: {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .notifications
                    }
                }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: notifsActive ? "bell.fill" : "bell")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(notifsActive ? DN.textDisplay : DN.textDisabled)

                        if viewModel.unreadCount > 0 {
                            Circle()
                                .fill(DN.accent)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -2)
                        }
                    }
                    .padding(.horizontal, DN.spaceXS)
                    .padding(.vertical, DN.spaceXS)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                let settingsActive = viewModel.viewState == .settings
                Button(action: {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .settings
                    }
                }) {
                    HStack(spacing: 2) {
                        if settingsActive {
                            Text("[")
                                .font(DN.label(10))
                                .foregroundColor(DN.textDisplay)
                        }
                        Image(systemName: settingsActive ? "gearshape.fill" : "gearshape")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(settingsActive ? DN.textDisplay : DN.textDisabled)
                        if settingsActive {
                            Text("]")
                                .font(DN.label(10))
                                .foregroundColor(DN.textDisplay)
                        }
                    }
                    .padding(.horizontal, DN.spaceXS)
                    .padding(.vertical, DN.spaceXS)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if viewModel.settings.showBattery {
                    BatteryView()
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(width: shapeWidth, height: notchH)
    }

    private func tabButton(label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(isActive ? "[ \(label) ]" : label)
                .font(DN.label(10))
                .tracking(1.2)
                .foregroundColor(isActive ? DN.textDisplay : DN.textDisabled)
                .padding(.horizontal, DN.spaceXS)
                .padding(.vertical, DN.spaceXS)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Battery

struct BatteryView: View {
    @State private var level: Int = 0
    @State private var isCharging: Bool = false
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: DN.spaceXS) {
            Text("\(level)%")
                .font(DN.mono(9))
                .foregroundColor(DN.textSecondary)
                .fixedSize()

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(DN.borderVisible, lineWidth: 0.8)
                    .frame(width: 18, height: 9)

                RoundedRectangle(cornerRadius: 1)
                    .fill(batteryColor)
                    .frame(width: max(CGFloat(level) / 100.0 * 15, 2), height: 6)
                    .padding(.leading, 1.5)

                RoundedRectangle(cornerRadius: 0.5)
                    .fill(DN.borderVisible)
                    .frame(width: 1.5, height: 4)
                    .offset(x: 18.5)
            }

            if isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7))
                    .foregroundColor(DN.textPrimary)
            }
        }
        .onAppear {
            updateBattery()
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                DispatchQueue.main.async { updateBattery() }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    private var batteryColor: Color {
        if isCharging { return DN.textPrimary }
        if level <= 20 { return DN.accent }
        return DN.textSecondary
    }

    private func updateBattery() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else { continue }
            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int { level = capacity }
            if let charging = desc[kIOPSIsChargingKey] as? Bool { isCharging = charging }
        }
    }
}

// MARK: - Settings

// MARK: - Notifications Panel

struct NotificationsPanel: View {
    @ObservedObject var viewModel: NotchViewModel

    // Group notifications by sourceId (or by id if no sourceId)
    private var grouped: [(key: String, title: String, items: [NotificationItem])] {
        var dict: [(key: String, title: String, items: [NotificationItem])] = []
        var seen: [String: Int] = [:]

        for notif in viewModel.notifications {
            let groupKey = notif.sourceId ?? notif.id
            if let idx = seen[groupKey] {
                dict[idx].items.append(notif)
            } else {
                seen[groupKey] = dict.count
                dict.append((key: groupKey, title: notif.title, items: [notif]))
            }
        }
        return dict
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            HStack {
                Text("NOTIFICATIONS")
                    .font(DN.label(10))
                    .tracking(1.5)
                    .foregroundColor(DN.textSecondary)

                Spacer()

                if viewModel.unreadCount > 0 {
                    Button(action: { viewModel.markAllRead() }) {
                        Text("MARK ALL READ")
                            .font(DN.label(7))
                            .tracking(0.8)
                            .foregroundColor(DN.textDisabled)
                            .padding(.horizontal, DN.spaceSM)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(DN.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, DN.spaceXS)

            if viewModel.notifications.isEmpty {
                VStack(spacing: DN.spaceSM) {
                    Spacer().frame(height: DN.spaceLG)
                    Text("NO NOTIFICATIONS")
                        .font(DN.label(9))
                        .tracking(0.8)
                        .foregroundColor(DN.textDisabled)
                    Text("Scheduled task results will appear here")
                        .font(DN.body(10))
                        .foregroundColor(DN.textDisabled.opacity(0.7))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DN.spaceXS) {
                        ForEach(grouped, id: \.key) { group in
                            NotificationGroupRow(
                                title: group.title,
                                items: group.items,
                                viewModel: viewModel
                            )
                        }
                    }
                }
            }
        }
        .onAppear {
            viewModel.loadNotifications()
        }
    }
}

struct NotificationGroupRow: View {
    let title: String
    let items: [NotificationItem]
    @ObservedObject var viewModel: NotchViewModel
    @State private var isExpanded = false

    private var unreadCount: Int { items.filter { !$0.read }.count }
    private var latest: NotificationItem { items.first! }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            HStack(spacing: DN.spaceSM) {
                Circle()
                    .fill(unreadCount > 0 ? DN.accent : .clear)
                    .frame(width: 5, height: 5)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DN.spaceXS) {
                        Text(title)
                            .font(DN.body(11, weight: unreadCount > 0 ? .medium : .regular))
                            .foregroundColor(unreadCount > 0 ? DN.textPrimary : DN.textSecondary)
                            .lineLimit(1)

                        if items.count > 1 {
                            Text("\(items.count)")
                                .font(DN.mono(8))
                                .foregroundColor(DN.textDisabled)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(DN.border)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }

                    HStack(spacing: DN.spaceXS) {
                        Text("Scheduled")
                            .font(DN.mono(8))
                            .foregroundColor(DN.textDisabled)
                        Text("·")
                            .foregroundColor(DN.textDisabled)
                        Text(notifDate(latest.createdAt))
                            .font(DN.mono(8))
                            .foregroundColor(DN.textDisabled)
                    }
                }

                Spacer()

                if isExpanded {
                    // Pause/resume the source task
                    if let sourceId = latest.sourceId {
                        Button(action: {
                            let task = viewModel.scheduledTasks.first { $0.id == sourceId }
                            viewModel.toggleScheduledTask(sourceId, enabled: !(task?.enabled ?? true))
                        }) {
                            let task = viewModel.scheduledTasks.first { $0.id == latest.sourceId }
                            Image(systemName: task?.enabled != false ? "pause.circle" : "play.circle")
                                .font(.system(size: 12))
                                .foregroundColor(task?.enabled != false ? DN.warning : DN.success)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            withAnimation(.easeOut(duration: DN.microDuration)) {
                                viewModel.deleteScheduledTask(sourceId)
                            }
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundColor(DN.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(DN.textDisabled)
            }
            .padding(.horizontal, DN.spaceSM)
            .padding(.vertical, DN.spaceXS + 2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: DN.microDuration)) {
                    isExpanded.toggle()
                }
            }

            // Expanded: show each run
            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { notif in
                        NotificationRunRow(notif: notif, viewModel: viewModel)
                    }
                }
                .padding(.leading, DN.spaceMD + DN.spaceSM)
                .padding(.trailing, DN.spaceSM)
                .padding(.bottom, DN.spaceXS)
                .transition(.opacity)
            }
        }
        .background(isExpanded ? DN.surface.opacity(0.5) : (unreadCount > 0 ? DN.surface.opacity(0.3) : .clear))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct NotificationRunRow: View {
    let notif: NotificationItem
    @ObservedObject var viewModel: NotchViewModel
    @State private var showBody = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DN.spaceXS) {
                Circle()
                    .fill(notif.read ? DN.textDisabled : DN.accent)
                    .frame(width: 3, height: 3)

                Text(notifDate(notif.createdAt))
                    .font(DN.mono(8))
                    .foregroundColor(notif.read ? DN.textDisabled : DN.textSecondary)

                Spacer()

                if notif.body != nil {
                    Image(systemName: showBody ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7))
                        .foregroundColor(DN.textDisabled)
                }
            }
            .padding(.vertical, DN.spaceXS)
            .contentShape(Rectangle())
            .onTapGesture {
                if notif.body != nil {
                    withAnimation(.easeOut(duration: DN.microDuration)) {
                        showBody.toggle()
                    }
                    if !notif.read {
                        viewModel.markNotificationRead(notif.id)
                    }
                }
            }

            if showBody, let body = notif.body, !body.isEmpty {
                MarkdownView(text: body, isFinal: true)
                    .padding(.bottom, DN.spaceXS)
                    .transition(.opacity)
            }
        }
    }
}

private func notifDate(_ iso: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: iso) ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }()
    guard let d = date else { return "" }
    let interval = Date().timeIntervalSince(d)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    let df = DateFormatter()
    df.dateFormat = "MMM d, h:mm a"
    return df.string(from: d)
}

// MARK: - Settings

struct SettingsPanel: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            Text("SETTINGS")
                .font(DN.label(10))
                .tracking(1.5)
                .foregroundColor(DN.textSecondary)
                .padding(.bottom, DN.spaceXS)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    SettingsSection(title: "CHAT") {
                        SettingsToggleRow(
                            icon: "bubble.left.and.text.bubble.right",
                            title: "Open chat on send",
                            subtitle: "Sending a message opens the conversation instantly",
                            isOn: $viewModel.settings.openChatOnSend
                        )
                        SettingsToggleRow(
                            icon: "arrow.counterclockwise",
                            title: "Restore last view",
                            subtitle: "Re-hover opens the last page instead of home",
                            isOn: $viewModel.settings.restoreLastView
                        )
                        SettingsToggleRow(
                            icon: "lock.open",
                            title: "Keep open in chat",
                            subtitle: "Don't auto-close when viewing a conversation",
                            isOn: $viewModel.settings.keepOpenInChat
                        )
                    }

                    SettingsSection(title: "DISPLAY") {
                        SettingsPickerRow(
                            icon: "calendar",
                            title: "Calendar",
                            subtitle: "Calendar display in overview",
                            options: CalendarMode.allCases.map { $0.label },
                            selection: Binding(
                                get: { CalendarMode.allCases.firstIndex(of: viewModel.settings.calendarMode) ?? 2 },
                                set: { viewModel.settings.calendarMode = CalendarMode.allCases[$0] }
                            )
                        )
                        SettingsToggleRow(
                            icon: "music.note",
                            title: "Now playing",
                            subtitle: "Show current music track in overview",
                            isOn: $viewModel.settings.showMusic
                        )
                        if viewModel.settings.showMusic {
                            SettingsPickerRow(
                                icon: "rectangle.expand.vertical",
                                title: "Player size",
                                subtitle: "Music widget size when space allows",
                                options: MusicSize.allCases.map { $0.label },
                                selection: Binding(
                                    get: { MusicSize.allCases.firstIndex(of: viewModel.settings.musicSize) ?? 0 },
                                    set: { viewModel.settings.musicSize = MusicSize.allCases[$0] }
                                )
                            )
                        }
                        SettingsToggleRow(
                            icon: "battery.75percent",
                            title: "Battery indicator",
                            subtitle: "Show battery in the top bar",
                            isOn: $viewModel.settings.showBattery
                        )
                        SettingsToggleRow(
                            icon: "circle.grid.3x3",
                            title: "Dot grid",
                            subtitle: "Animated dot matrix background",
                            isOn: $viewModel.settings.showDotGrid
                        )
                        if viewModel.settings.showDotGrid {
                            SettingsColorRow(
                                icon: "paintbrush",
                                title: "Grid color",
                                subtitle: "Dot grid color",
                                selectedHex: $viewModel.settings.dotGridColor
                            )
                            SettingsSliderRow(
                                icon: "circle.lefthalf.filled",
                                title: "Grid opacity",
                                subtitle: "Brightness of the dot grid",
                                value: $viewModel.settings.dotGridOpacity,
                                range: 0.1...1.0
                            )
                        }
                    }

                    SettingsSection(title: "AGENTS") {
                        SettingsToggleRow(
                            icon: "waveform",
                            title: "Live state",
                            subtitle: "Real-time tool activity for agents",
                            isOn: $viewModel.settings.showAgentLiveState
                        )
                        SettingsToggleRow(
                            icon: "rectangle.compress.vertical",
                            title: "Compact rows",
                            subtitle: "Smaller rows in the agent list",
                            isOn: $viewModel.settings.compactAgentRows
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Settings Components

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(DN.label(8))
                .tracking(1.2)
                .foregroundColor(DN.textDisabled)
                .padding(.leading, 4)
                .padding(.top, DN.spaceSM)
                .padding(.bottom, DN.spaceXS)

            VStack(spacing: 1) {
                content
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? DN.textPrimary : DN.textDisabled)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DN.body(11))
                    .foregroundColor(DN.textPrimary)
                Text(subtitle)
                    .font(DN.mono(8))
                    .foregroundColor(DN.textDisabled)
                    .lineLimit(1)
            }

            Spacer()

            SettingsToggle(isOn: $isOn)
        }
        .padding(.horizontal, DN.spaceSM)
        .padding(.vertical, 6)
        .background(DN.surface)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: DN.microDuration)) {
                isOn.toggle()
            }
        }
    }
}

struct SettingsPickerRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DN.textPrimary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DN.body(11))
                    .foregroundColor(DN.textPrimary)
                Text(subtitle)
                    .font(DN.mono(8))
                    .foregroundColor(DN.textDisabled)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 1) {
                ForEach(0..<options.count, id: \.self) { i in
                    Button(action: {
                        withAnimation(.easeOut(duration: DN.microDuration)) {
                            selection = i
                        }
                    }) {
                        Text(options[i])
                            .font(DN.label(7))
                            .tracking(0.4)
                            .foregroundColor(selection == i ? DN.textDisplay : DN.textDisabled)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(selection == i ? DN.borderVisible : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(DN.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DN.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, DN.spaceSM)
        .padding(.vertical, 6)
        .background(DN.surface)
    }
}

struct SettingsSliderRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        VStack(alignment: .leading, spacing: DN.spaceXS) {
            HStack(spacing: DN.spaceSM) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DN.textPrimary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DN.body(11))
                        .foregroundColor(DN.textPrimary)
                    Text(subtitle)
                        .font(DN.mono(8))
                        .foregroundColor(DN.textDisabled)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(Int(value * 100))%")
                    .font(DN.mono(9))
                    .foregroundColor(DN.textSecondary)
                    .frame(width: 32, alignment: .trailing)
            }

            Slider(value: $value, in: range)
                .tint(DN.textSecondary)
        }
        .padding(.horizontal, DN.spaceSM)
        .padding(.vertical, 6)
        .background(DN.surface)
    }
}

struct SettingsColorRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var selectedHex: String

    private let presets: [(String, String)] = [
        ("#FFFFFF", "White"),
        ("#D97757", "Orange"),
        ("#00B4D8", "Cyan"),
        ("#D71921", "Red"),
        ("#4A9E5C", "Green"),
        ("#D4A843", "Yellow"),
        ("#A855F7", "Purple"),
        ("#10A37F", "Teal"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DN.spaceXS) {
            HStack(spacing: DN.spaceSM) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DN.textPrimary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DN.body(11))
                        .foregroundColor(DN.textPrimary)
                    Text(subtitle)
                        .font(DN.mono(8))
                        .foregroundColor(DN.textDisabled)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(presets, id: \.0) { hex, _ in
                    Button(action: {
                        withAnimation(.easeOut(duration: DN.microDuration)) {
                            selectedHex = hex
                        }
                    }) {
                        Circle()
                            .fill(Color(hex: UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(selectedHex == hex ? DN.textDisplay : .clear, lineWidth: 2)
                            )
                            .overlay(
                                Circle()
                                    .stroke(DN.black, lineWidth: selectedHex == hex ? 1 : 0)
                                    .padding(1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, DN.spaceSM)
        .padding(.vertical, 6)
        .background(DN.surface)
    }
}

struct SettingsToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? DN.success.opacity(0.8) : DN.border)
                .frame(width: 32, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 2)
        }
        .animation(.easeOut(duration: DN.microDuration), value: isOn)
    }
}
