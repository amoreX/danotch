import SwiftUI
import AppKit

struct NotchShellView: View {
    @ObservedObject var viewModel: NotchViewModel

    @Namespace private var tabNS

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    private var notchW: CGFloat { screen.notchWidth }
    private var notchH: CGFloat { screen.notchHeight }
    private var expanded: Bool { viewModel.isExpanded }

    private let notchContentWidth: CGFloat = 540
    private let widgetEditPanelWidth: CGFloat = 400

    private var expandedWidth: CGFloat {
        viewModel.isWidgetEditMode ? notchContentWidth + widgetEditPanelWidth : notchContentWidth
    }
    private var expandedHeight: CGFloat {
        viewModel.settings.notchExpandedHeight
    }

    // Single source of truth — all size derived from viewModel.notchSize
    private var shapeWidth: CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchW + 200 : notchW + 140
        }
        switch viewModel.notchSize {
        case .collapsed: return notchW
        case .nudging:   return notchW * 1.2
        case .expanded:  return expandedWidth
        }
    }

    private var shapeHeight: CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchH + 80 : notchH + 28
        }
        switch viewModel.notchSize {
        case .collapsed: return notchH
        case .nudging:   return notchH * 1.5
        case .expanded:  return notchH + expandedHeight
        }
    }

    private var bottomRadius: CGFloat {
        if viewModel.isPeeking { return 12 }
        switch viewModel.notchSize {
        case .collapsed: return 8
        case .nudging:   return 10
        case .expanded:  return 16
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Fake reverse-bevel corner ears — always rendered, size tracks bottomRadius
            HStack(spacing: 0) {
                Spacer()
                NotchCornerLeft()
                    .fill(DN.black)
                    .frame(width: bottomRadius, height: bottomRadius)
                Color.clear.frame(width: shapeWidth)
                NotchCornerRight()
                    .fill(DN.black)
                    .frame(width: bottomRadius, height: bottomRadius)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomRadius)
            .allowsHitTesting(false)

            // Clipped notch panel
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
                    if viewModel.settings.showDotGrid {
                        DotGridView(dotColor: viewModel.settings.dotGridSwiftColor)
                            .padding(.top, notchH)
                            .opacity(viewModel.settings.dotGridOpacity)
                            .allowsHitTesting(false)
                    }

                    if viewModel.isAuthenticated {
                        expandedTopBar
                            .transition(.opacity)

                        expandedContent
                            .padding(.top, notchH + 1)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                            .frame(width: shapeWidth, alignment: .top)
                    } else {
                        NotchAuthView(auth: AuthManager.shared)
                            .padding(.top, notchH + 1)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                            .frame(width: 520, alignment: .top)
                            .transition(.opacity)
                    }
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
            .shadow(
                color: .black.opacity(viewModel.notchSize == .expanded ? 0.55 : 0),
                radius: viewModel.notchSize == .expanded ? 28 : 0,
                y: viewModel.notchSize == .expanded ? 10 : 0
            )
        }
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
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: viewModel.notchSize)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.isWidgetEditMode)
        .animation(.easeOut(duration: 0.25), value: viewModel.isPeeking)
        .animation(.easeOut(duration: 0.2), value: viewModel.peekHovering)
        .animation(.easeOut(duration: 0.18), value: viewModel.viewState)
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
        // Seal the physical notch edge — bleeds 4px above to cover any animation gap
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DN.black)
                .frame(height: 6)
                .offset(y: -4)
        }
    }

    // MARK: - Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        if viewModel.isWidgetEditMode {
            HStack(spacing: 0) {
                NotchContentView(viewModel: viewModel)
                    .frame(width: notchContentWidth - 8)  // subtract the 4px horizontal padding each side

                Rectangle()
                    .fill(DN.border)
                    .frame(width: 1)
                    .padding(.vertical, DN.spaceXS)

                WidgetEditPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
        } else {
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
            // Left: Home + Agents (text labels, left-aligned)
            HStack(spacing: 4) {
                Spacer().frame(width: 4)
                navTextTab("HOME", id: "home", active: viewModel.viewState == .overview) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.viewState = .overview }
                }
                navTextTab("AGENTS", id: "agents", active: viewModel.isInTaskOrChat) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.viewState = .taskList }
                }
                let statsActive = viewModel.viewState == .stats || viewModel.viewState == .processList
                navIconTab(id: "stats", active: statsActive) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.viewState = .stats }
                } icon: {
                    Image(systemName: statsActive ? "chart.bar.fill" : "chart.bar")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: notchW + DN.spaceMD)

            // Right: Stats + Notifications + Settings + Battery
            HStack(spacing: 4) {
                

                let notifsActive = viewModel.viewState == .notifications
                navIconTab(id: "notifs", active: notifsActive, badge: viewModel.unreadCount) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.viewState = .notifications }
                } icon: {
                    Image(systemName: notifsActive ? "bell.fill" : "bell")
                        .font(.system(size: 11, weight: .medium))
                }

                let settingsActive = viewModel.viewState == .settings
                navIconTab(id: "settings", active: settingsActive) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { viewModel.viewState = .settings }
                } icon: {
                    Image(systemName: settingsActive ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 11, weight: .medium))
                }

                if viewModel.settings.showBattery {
                    BatteryView(monitor: viewModel.batteryMonitor)
                        .padding(.leading, 4)
                }
                Spacer().frame(width: 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: expandedWidth, height: notchH)
    }

    private func navIconTab(id: String, active: Bool, badge: Int = 0, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> some View) -> some View {
        NavTabButton(id: id, active: active, ns: tabNS, action: action) {
            ZStack(alignment: .topTrailing) {
                icon()
                    .frame(width: 16, height: 16)
                if badge > 0 {
                    Circle()
                        .fill(DN.accent)
                        .frame(width: 5, height: 5)
                        .offset(x: 4, y: -4)
                }
            }
        }
    }

    private func navTextTab(_ label: String, id: String, active: Bool, action: @escaping () -> Void) -> some View {
        NavTabButton(id: id, active: active, ns: tabNS, action: action) {
            Text(label)
                .font(DN.label(10))
                .tracking(0.6)
        }
    }
}

// MARK: - Notch Corner Shapes

/// Black quarter-circle that creates the concave reverse-bevel at the top-left of the notch.
/// Occupies a small square just to the left of the notch edge; the arc carves out the corner
/// so the notch appears to smoothly curve into the menu bar like the physical hardware.
// Left corner piece: concave bite at bottom-LEFT (outer corner, away from notch).
private struct NotchCornerLeft: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.minX, y: rect.maxY),
            radius: rect.width,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Nav Tab Button (sliding pill via matchedGeometryEffect)

private struct NavTabButton<Label: View>: View {
    let id: String
    let active: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 10, weight: active ? .semibold : .medium))
                .foregroundColor(active ? DN.textDisplay : isHovered ? DN.textPrimary : DN.textDisabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    if active {
                        Capsule()
                            .fill(Color.white.opacity(0.12))
                            .matchedGeometryEffect(id: "navPill", in: ns)
                    } else if isHovered {
                        Capsule()
                            .fill(Color.white.opacity(0.06))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .handCursor()
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: active)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// Right corner piece: concave bite at bottom-RIGHT (outer corner, away from notch).
private struct NotchCornerRight: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: rect.width,
            startAngle: .degrees(-90),
            endAngle: .degrees(180),
            clockwise: true
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Battery

struct BatteryView: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        HStack(spacing: DN.spaceXS) {
            Text("\(monitor.level)%")
                .font(DN.mono(9))
                .foregroundColor(DN.textSecondary)
                .fixedSize()

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(DN.borderVisible, lineWidth: 0.8)
                    .frame(width: 18, height: 9)

                RoundedRectangle(cornerRadius: 1)
                    .fill(batteryColor)
                    .frame(width: max(CGFloat(monitor.level) / 100.0 * 15, 2), height: 6)
                    .padding(.leading, 1.5)

                RoundedRectangle(cornerRadius: 0.5)
                    .fill(DN.borderVisible)
                    .frame(width: 1.5, height: 4)
                    .offset(x: 18.5)
            }

            if monitor.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 7))
                    .foregroundColor(DN.textPrimary)
            }
        }
    }

    private var batteryColor: Color {
        if monitor.isCharging { return DN.textPrimary }
        if monitor.level <= 20 { return DN.accent }
        return DN.textSecondary
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
    formatRelativeDate(iso, fallbackFormat: "MMM d, h:mm a")
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

                    SettingsSection(title: "WIDGETS") {
                        Button(action: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                viewModel.viewState = .overview
                                viewModel.isWidgetEditMode = true
                            }
                        }) {
                            HStack(spacing: DN.spaceSM) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(DN.accent)
                                    .frame(width: 18)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Edit Widgets")
                                        .font(DN.body(11))
                                        .foregroundColor(DN.textPrimary)
                                    Text("\(viewModel.settings.widgetSlots.count) active · tap to add or remove")
                                        .font(DN.mono(8))
                                        .foregroundColor(DN.textDisabled)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(DN.textDisabled)
                            }
                            .padding(.horizontal, DN.spaceSM)
                            .padding(.vertical, 8)
                            .background(DN.surface)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    SettingsSection(title: "DISPLAY") {
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

                    SettingsSection(title: "MUSIC") {
                        HStack(spacing: DN.spaceSM) {
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(DN.textDisabled)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text("Music source")
                                    .font(DN.body(11))
                                    .foregroundColor(DN.textPrimary)
                                Text("Which app to show now playing from")
                                    .font(DN.mono(8))
                                    .foregroundColor(DN.textDisabled)
                            }

                            Spacer()

                            HStack(spacing: 2) {
                                ForEach(MusicSource.allCases, id: \.rawValue) { src in
                                    Button(src.label) {
                                        viewModel.settings.musicSource = src
                                    }
                                    .font(DN.label(7))
                                    .tracking(0.5)
                                    .foregroundColor(viewModel.settings.musicSource == src ? DN.textDisplay : DN.textDisabled)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(viewModel.settings.musicSource == src ? Color.white.opacity(0.1) : Color.clear)
                                    )
                                    .buttonStyle(.plain)
                                    .handCursor()
                                }
                            }
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DN.surface))
                        }
                        .padding(.horizontal, DN.spaceSM)
                        .padding(.vertical, 6)
                        .background(DN.surface)
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

                    SettingsSection(title: "INTEGRATIONS") {
                        AppConnectionRow(viewModel: viewModel, appType: "gmail", displayName: "Gmail", icon: "envelope.fill")
                        AppConnectionRow(viewModel: viewModel, appType: "googlecalendar", displayName: "Google Calendar", icon: "calendar")
                        AppConnectionRow(viewModel: viewModel, appType: "googledocs", displayName: "Google Docs", icon: "doc.text.fill")
                        AppConnectionRow(viewModel: viewModel, appType: "github", displayName: "GitHub", icon: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
        }
    }

}

// MARK: - Widget Edit Panel

struct WidgetEditPanel: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var searchText: String = ""

    private var inactiveWidgets: [PinnedWidget] {
        let active = Set(viewModel.settings.widgetSlots.map { $0.type })
        let all = PinnedWidget.allCases.filter { !active.contains($0) }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.label.lowercased().contains(searchText.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("ADD WIDGETS")
                    .font(DN.label(9))
                    .tracking(1.0)
                    .foregroundColor(DN.textSecondary)

                Spacer()

                Button(action: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        viewModel.isWidgetEditMode = false
                    }
                }) {
                    Text("DONE")
                        .font(DN.label(8))
                        .tracking(0.6)
                        .foregroundColor(DN.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(DN.accent.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, DN.spaceSM)

            // Search bar
            HStack(spacing: DN.spaceXS) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundColor(DN.textDisabled)

                TextField("Search widgets...", text: $searchText)
                    .font(DN.body(11))
                    .foregroundColor(DN.textPrimary)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(DN.textDisabled)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DN.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(DN.border, lineWidth: 1))
            .padding(.bottom, DN.spaceSM)

            // Inactive widget list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    if inactiveWidgets.isEmpty {
                        VStack(spacing: DN.spaceXS) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 20))
                                .foregroundColor(DN.success.opacity(0.6))
                            Text(searchText.isEmpty ? "All widgets active" : "No matches")
                                .font(DN.body(10))
                                .foregroundColor(DN.textDisabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, DN.spaceMD)
                    } else {
                        ForEach(inactiveWidgets, id: \.rawValue) { widget in
                            Button(action: {
                                withAnimation(.easeOut(duration: DN.microDuration)) {
                                    viewModel.settings.widgetSlots.append(
                                        WidgetSlot(type: widget, size: widget.defaultSize)
                                    )
                                }
                            }) {
                                HStack(spacing: DN.spaceSM) {
                                    Image(systemName: widget.icon)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(DN.textSecondary)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(widget.label)
                                            .font(DN.body(11))
                                            .foregroundColor(DN.textPrimary)
                                        Text(widgetSubtitle(widget))
                                            .font(DN.mono(8))
                                            .foregroundColor(DN.textDisabled)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 13))
                                        .foregroundColor(DN.accent)
                                }
                                .padding(.horizontal, DN.spaceSM)
                                .padding(.vertical, 6)
                                .background(DN.surface)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.leading, DN.spaceSM)
    }

    private func widgetSubtitle(_ w: PinnedWidget) -> String {
        switch w {
        case .clock:      return "Digital clock & date"
        case .calendar:   return "Date strip & events"
        case .music:      return "Now playing controls"
        case .cpu:        return "CPU usage gauge"
        case .battery:    return "Battery level ring"
        case .agentCount: return "Running AI agents"
        case .ram:        return "Memory usage"
        case .disk:       return "Storage usage"
        case .network:    return "Upload & download speeds"
        case .uptime:     return "System uptime counter"
        case .processes:  return "Running process count"
        }
    }
}

// MARK: - Settings Components

// MARK: - App Connection Row (Generic)

struct AppConnectionRow: View {
    @ObservedObject var viewModel: NotchViewModel
    let appType: String
    let displayName: String
    let icon: String

    private var isConnected: Bool { viewModel.appConnected[appType] ?? false }
    private var isLoading: Bool { viewModel.appLoading[appType] ?? false }
    private var error: String? { viewModel.appError[appType] ?? nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DN.spaceSM) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isConnected ? DN.success : DN.textDisabled)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(DN.body(11))
                        .foregroundColor(DN.textPrimary)
                    Text(isLoading ? "Checking..." : (isConnected ? "Connected" : "Not connected"))
                        .font(DN.mono(8))
                        .foregroundColor(isConnected ? DN.success : DN.textDisabled)
                        .lineLimit(1)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 32, height: 18)
                } else {
                    Button(action: {
                        if isConnected {
                            viewModel.disconnectApp(appType)
                        } else {
                            viewModel.connectApp(appType)
                        }
                    }) {
                        Text(isConnected ? "DISCONNECT" : "CONNECT")
                            .font(DN.label(7))
                            .tracking(0.6)
                            .foregroundColor(isConnected ? DN.accent : DN.success)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isConnected ? DN.accent.opacity(0.4) : DN.success.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error = error {
                Text(error)
                    .font(DN.mono(8))
                    .foregroundColor(DN.accent)
                    .lineLimit(2)
                    .padding(.top, 4)
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, DN.spaceSM)
        .padding(.vertical, 6)
        .background(DN.surface)
        .onAppear {
            viewModel.checkAppStatus(appType)
        }
    }
}

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
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isOn ? DN.accent : DN.textDisabled)
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
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: DN.microDuration)) {
                isOn.toggle()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeOut(duration: 0.08)) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.12)) { isPressed = false }
                }
        )
        .animation(.easeOut(duration: DN.microDuration), value: isPressed)
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
        ("#00E5A0", "Teal"),    // Option A accent — first slot
        ("#FFFFFF", "White"),
        ("#D97757", "Orange"),
        ("#00B4D8", "Cyan"),
        ("#D4A843", "Amber"),
        ("#4A9E5C", "Green"),
        ("#A855F7", "Purple"),
        ("#E05252", "Red"),
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
                .fill(isOn ? DN.accent.opacity(0.75) : DN.border)
                .frame(width: 32, height: 18)

            Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 2)
        }
        .animation(.easeOut(duration: DN.microDuration), value: isOn)
    }
}
