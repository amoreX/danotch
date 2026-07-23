import SwiftUI
import AppKit
import UserNotifications

struct NotchShellView: View {
    @ObservedObject var viewModel: NotchViewModel

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    private var notchW: CGFloat { screen.notchWidth }
    private var notchH: CGFloat { screen.notchHeight }
    private var expanded: Bool { viewModel.isExpanded }

    // Canonical expanded size for every view *except* the Today overview,
    // which sizes itself to its pinned widget count (see `contentH` below).
    // Inner ScrollViews handle overflow beyond these sizes.
    static let expandedW: CGFloat = 540
    static let expandedH: CGFloat = 320

    /// Height of the expanded content area for the current view state.
    /// Only `.overview` (the Today page) varies with widget count; every
    /// other tab keeps the fixed canonical height so switching tabs away
    /// from Today doesn't jump around.
    private var contentH: CGFloat {
        switch viewModel.viewState {
        case .overview:
            return viewModel.settings.todayExpandedH
        default:
            return Self.expandedH
        }
    }

    private var shapeWidth: CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchW + 200 : notchW + 140
        }
        if !expanded { return notchW }
        return Self.expandedW
    }

    private var shapeHeight: CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchH + 80 : notchH + 28
        }
        if !expanded { return notchH }
        if viewModel.isQuickPrompt { return notchH + Self.quickPromptH }
        return notchH + contentH
    }

    static let quickPromptH: CGFloat = 58

    private var bottomRadius: CGFloat {
        if viewModel.isPeeking { return 12 }
        // Apple nested-corner rule: outer = inner + padding.
        // Inner capsule ≈ 19pt half-height; outer padding = spaceMD (12).
        // → 31pt; round to 32pt for a clean visual.
        return expanded ? 32 : 8
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

            if expanded && !viewModel.isPeeking && viewModel.isQuickPrompt {
                quickPromptHintBar
                    .transition(.opacity)

                QuickPromptView(viewModel: viewModel)
                    .padding(.top, notchH + 1)
                    .padding(.horizontal, DN.spaceMD)
                    .padding(.bottom, DN.spaceMD)
                    .frame(width: shapeWidth, alignment: .bottom)
                    .transition(.opacity)
            }

            if expanded && !viewModel.isPeeking && !viewModel.isQuickPrompt {
                expandedTopBar
                    .transition(.opacity)

                // Cross-fade between views; the surrounding shape never changes size,
                // so no layout reflow needed.
                expandedContent
                    .padding(.top, notchH + 1)
                    .padding(.horizontal, 10)
                    .padding(.bottom, bottomPaddingForState)
                    .frame(width: shapeWidth, alignment: .top)
                    .id(viewModel.viewState.transitionKey)
                    .transition(.opacity)
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
        // Shoulders sit OUTSIDE the clip so they extend left/right into the
        // menu-bar zone and fillet the panel/menu-bar junction. They're
        // ALWAYS present (size animates from 0 when collapsed to bottomRadius
        // when expanded), so the bevels grow with the same spring as the
        // panel itself.
        .overlay(alignment: .top) {
            shoulders
        }
        // Shadow below the expanded panel — no compositingGroup so glassEffect
        // can composite against the desktop without triggering constraint cycles.
        // A positive y-offset means the shadow falls downward; any top-bleed
        // is hidden behind the physical notch / menu bar edge.
        .shadow(
            color: Color.black.opacity(expanded ? 0.35 : 0),
            radius: expanded ? 24 : 0,
            x: 0,
            y: expanded ? 12 : 0
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
        .animation(DN.expandSpring, value: expanded)
        .animation(DN.expandSpring, value: viewModel.isQuickPrompt)
        .animation(DN.peekSpring, value: viewModel.isPeeking)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.peekHovering)
        .animation(DN.viewStateSpring, value: viewModel.viewState)
    }

    private var notchShape: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0,
            style: .continuous
        )

        // Liquid glass base
        let glass = Color.clear
            .perchGlass(tint: Color.black.opacity(0.18), in: shape)
            .clipShape(shape)

        // Black-to-transparent gradient overlaid on top so the physical notch
        // area stays solid black and dissolves into glass further down.
        let gradientEnd: Double = expanded ? 0.22 : 1.0
        let clearStart:  Double = expanded ? 0.48 : 1.0

        return glass.overlay(
            LinearGradient(
                stops: [
                    .init(color: .black,        location: 0),
                    .init(color: .black,        location: gradientEnd),
                    .init(color: .clear,        location: clearStart),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(shape)
        )
    }

    // Shoulders flank the dropdown panel's top-left and top-right corners.
    // They sit in the menu-bar zone, each with a concave bite in its
    // bottom-inner corner so the menu bar appears to fillet smoothly down
    // into the panel.
    //
    //   ┌── menu bar ───╮       ╭── menu bar ───┐
    //                    ╲     ╱
    //                     │ ┌─┴─┐ │
    //                     └─┤   ├─┘
    //                       │ panel │
    //
    // Left shoulder carved at BOTTOM-RIGHT, right shoulder at BOTTOM-LEFT.
    private var shoulders: some View {
        // Shoulders only exist while expanded — collapse to size 0 when
        // the notch is closed so the spring on `expanded` also animates
        // them in and out smoothly. Decoupled from bottomRadius so the
        // bevel stays small even when the panel uses a large outer radius.
        let shoulderSize: CGFloat = 12
        let size: CGFloat = expanded && !viewModel.isPeeking ? shoulderSize : 0
        return Color.clear
            .frame(width: shapeWidth, height: size)
            .overlay(alignment: .topLeading) {
                NotchShoulder(corner: .bottomLeft)
                    .fill(Color.black)
                    .frame(width: size, height: size)
                    .offset(x: -size + 0.5, y: 0)
            }
            .overlay(alignment: .topTrailing) {
                NotchShoulder(corner: .bottomRight)
                    .fill(Color.black)
                    .frame(width: size, height: size)
                    .offset(x: size - 0.5, y: 0)
            }
            .allowsHitTesting(false)
    }

    // MARK: - Expanded Content

    /// Scrolling views push their content to the notch's bottom edge so the
    /// smartScrollFade lands directly on the rounded panel boundary.
    private var bottomPaddingForState: CGFloat {
        switch viewModel.viewState {
        case .stats, .processList, .settings, .notifications:
            return 0
        default:
            return 10
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(spacing: 6) {
            if viewModel.connectionState.needsAttention {
                DeviceConnectionBanner(viewModel: viewModel)
            }
            Group {
                switch viewModel.viewState {
                case .overview, .taskList, .agentChat, .agents:
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(viewModel.connectionAnnouncement)
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
    //
    // Layout grid: [LEFT TABS] [physical notch gap] [RIGHT TABS]
    // Both side groups sit on the same baseline (vertically centered to notchH)
    // and all controls are pill-shaped with a single height to share a baseline.

    // Quick-prompt mode hint bar — sits in the top-bar zone flanking the
    // physical notch. Mirrors the expandedTopBar layout grid so the pills
    // sit on the same baseline as the regular top-bar tabs.
    private var quickPromptHintBar: some View {
        let sideInset: CGFloat = DN.spaceMD

        return HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: sideInset)

            hintPill(key: "Enter", caption: "to send")

            Spacer(minLength: DN.spaceSM)
            Color.clear.frame(width: notchW)
            Spacer(minLength: DN.spaceSM)

            hintPill(key: "Esc", caption: "to dismiss")

            Color.clear.frame(width: sideInset)
        }
        .frame(width: shapeWidth, height: notchH)
    }

    private func hintPill(key: String, caption: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .perchGlass(in: Capsule())
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // Top bar: discrete capsule glass buttons, never .glassProminent (its
    // automatic foreground inversion turns active text black). Active state
    // is conveyed by a brighter tint on the same .glass style so the text
    // color and capsule shape stay constant across states.
    // Layout: [pad] [LEFT CLUSTER] [grow] [physical notch] [grow] [RIGHT CLUSTER] [pad]
    private var expandedTopBar: some View {
        let sideInset: CGFloat = DN.spaceMD

        return HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: sideInset)

            // Left cluster — Today + Agents
            HStack(spacing: 6) {
                topBarTab("Today", isActive: viewModel.viewState == .overview) {
                    withAnimation(DN.transition) { viewModel.viewState = .overview }
                }
                topBarIcon(
                    "sparkles",
                    isActive: viewModel.viewState == .agents || viewModel.isInTaskOrChat
                ) {
                    withAnimation(DN.transition) { viewModel.viewState = .taskList }
                }
            }

            Spacer(minLength: DN.spaceSM)
            Color.clear.frame(width: notchW)
            Spacer(minLength: DN.spaceSM)

            // Right cluster — Stats / Bell / Settings
            HStack(spacing: 6) {
                topBarTab("Stats", isActive: viewModel.viewState == .stats || viewModel.viewState == .processList) {
                    withAnimation(DN.transition) { viewModel.viewState = .stats }
                }
                topBarIcon(
                    viewModel.viewState == .notifications ? "bell.fill" : "bell",
                    isActive: viewModel.viewState == .notifications,
                    badge: viewModel.unreadCount > 0
                ) {
                    withAnimation(DN.transition) { viewModel.viewState = .notifications }
                }
                topBarIcon(
                    viewModel.viewState == .settings ? "gearshape.fill" : "gearshape",
                    isActive: viewModel.viewState == .settings
                ) {
                    withAnimation(DN.transition) { viewModel.viewState = .settings }
                }
            }

            Color.clear.frame(width: sideInset)
        }
        .frame(width: shapeWidth, height: notchH)
    }

    /// A pill-shaped text button. Active uses a deep navy tint; the label
    /// stays white in every state. We fire the action on tap-release (not
    /// press) so there's no pressed-state color flash — only the post-click
    /// active state is visible.
    private func topBarTab(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .perchGlass(tint: isActive ? DN.activeAccent : nil, in: Capsule())
            .contentShape(.capsule)
            .onTapGesture(perform: action)
    }

    /// A pill-shaped icon button. Same rules as topBarTab — release-fire,
    /// no press flash, white glyph in every state.
    private func topBarIcon(_ icon: String, isActive: Bool, badge: Bool = false, action: @escaping () -> Void) -> some View {
        Image(systemName: icon)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 26, height: 22)
            .perchGlass(tint: isActive ? DN.activeAccent : nil, in: Capsule())
            .contentShape(.capsule)
            .onTapGesture(perform: action)
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle()
                        .fill(.red)
                        .frame(width: 5, height: 5)
                        .offset(x: -2, y: 2)
                }
            }
    }

}

// MARK: - Notch shoulder shape
//
// A unit square with one rounded *concave* corner. Used to bevel the
// junction between the notch and the screen's top edge. The carved corner
// is positioned so the arc curves outward, away from the menu bar, creating
// the visual illusion of a smooth fillet (the same trick used by macOS for
// its hardware notch and by display-mask apps like Notchbar).
struct NotchShoulder: Shape {
    enum Corner {
        case bottomLeft, bottomRight
    }

    let corner: Corner

    // Black tile, one of its BOTTOM corners carved by a concave quarter-
    // circle. Sits in the menu-bar zone flanking the dropdown panel so the
    // menu bar visually fillets down into the panel's top corner.
    //
    // Coords: y=0 top, y=h bottom.
    // Concave bite: arc center sits at the INNER corner of the bite (one
    // radius diagonally inward from the physical corner being carved).
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let r = min(w, h)

        switch corner {
        case .bottomRight:
            //   ┌──────────┐
            //   │           │
            //   │           │
            //   │            ╲   ← bite curves down-and-left, hugging the
            //   └─────────╮  ╲     panel's top-left rounded corner outside
            //
            // Arc center = (w - r, h - r). Sweep from (w, h-r) — right edge
            // — to (w-r, h) — bottom edge. clockwise:false in SwiftUI's
            // y-down system produces the visually clockwise sweep that
            // carves a concave bite.
            // CSS-style inverse border-radius: quarter-circle hole carved
            // out of the corner that touches the panel. Arc center sits AT
            // the carved corner (w, h); the arc sweeps OUT of the square's
            // body leaving a concave quarter-circle bite — exactly the CSS
            // `border-radius` shape but inverted.
            p.move(to: CGPoint(x: 0, y: 0))                   // top-left
            p.addLine(to: CGPoint(x: w, y: 0))                // top-right
            p.addLine(to: CGPoint(x: w, y: h - r))            // down right edge to bite start
            p.addArc(
                center: CGPoint(x: w, y: h),
                radius: r,
                startAngle: .degrees(270),                    // (w, h-r) — straight up from center
                endAngle: .degrees(180),                      // (w-r, h) — straight left from center
                clockwise: true
            )
            p.addLine(to: CGPoint(x: 0, y: h))                // bottom-left
            p.closeSubpath()

        case .bottomLeft:
            // RIGHT shoulder. Concave bite in BOTTOM-LEFT (mirror).
            //         ┌──────────┐
            //         │          │
            //         │          │
            //        ╱            │
            //       ╱  ╭─────────┘
            //
            // Arc center = (r, h - r). Sweep from (0, h-r) — left edge —
            // to (r, h) — bottom edge.
            // Mirror of bottomRight. Arc center at (0, h) — the carved
            // corner — quarter-circle hole carved out of bottom-left.
            p.move(to: CGPoint(x: w, y: 0))                   // top-right
            p.addLine(to: CGPoint(x: 0, y: 0))                // top-left
            p.addLine(to: CGPoint(x: 0, y: h - r))            // down left edge to bite start
            p.addArc(
                center: CGPoint(x: 0, y: h),
                radius: r,
                startAngle: .degrees(270),                    // (0, h-r) — straight up from center
                endAngle: .degrees(0),                        // (r, h)   — straight right from center
                clockwise: false
            )
            p.addLine(to: CGPoint(x: w, y: h))                // bottom-right
            p.closeSubpath()
        }
        return p
    }
}

private struct DeviceConnectionBanner: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.connectionState.icon)
            Text(viewModel.connectionState.title)
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            if viewModel.connectionState.requiresUpdate {
                Button("Check for Updates") { UpdateController.shared.checkForUpdates() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
            }
            if viewModel.connectionState.canRetry {
                Button("Retry") { viewModel.retryDeviceConnection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
            }
            if viewModel.connectionState.canCancel {
                Button("Cancel") { viewModel.cancelDeviceConnection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color.orange.opacity(0.24), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.connectionState.announcement)
    }
}

extension DeviceConnectionState {
    var requiresUpdate: Bool {
        self == .unsupportedProtocol
    }

    var needsAttention: Bool {
        switch self {
        case .offline, .expired, .revoked, .interrupted,
             .reenrollmentRequired, .unsupportedProtocol:
            return true
        default:
            return false
        }
    }

    var canRetry: Bool {
        switch self {
        case .offline, .expired, .interrupted, .reenrollmentRequired, .cancelled:
            return true
        default:
            return false
        }
    }

    var canCancel: Bool {
        switch self {
        case .enrolling, .connecting, .offline, .expired, .interrupted:
            return true
        default:
            return false
        }
    }

    var canReenroll: Bool {
        switch self {
        case .revoked, .reenrollmentRequired:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .signedOut: return "Signed out"
        case .enrolling: return "Enrolling this Mac"
        case .connecting: return "Connecting"
        case .connected: return "Securely connected"
        case .offline: return "Offline"
        case .expired: return "Session expired"
        case .revoked: return "Device revoked"
        case .interrupted: return "Connection interrupted"
        case .reenrollmentRequired: return "Re-enrollment required"
        case .unsupportedProtocol: return "Update required"
        case .cancelled: return "Connection cancelled"
        }
    }

    var detail: String {
        switch self {
        case .offline(let reason), .revoked(let reason),
             .interrupted(let reason), .reenrollmentRequired(let reason):
            return reason
        case .connected(let deviceID):
            return "Authenticated outbound device channel · \(deviceID)"
        case .connecting(let attempt):
            return "Requesting a one-use gateway ticket · attempt \(attempt + 1)"
        case .expired:
            return "The one-use ticket or account session expired."
        case .unsupportedProtocol:
            return "This app cannot safely connect to the server protocol."
        case .enrolling:
            return "Creating a non-exportable device identity and binding it to this account."
        case .signedOut:
            return "Sign in to connect this Mac."
        case .cancelled:
            return "Automatic reconnection is paused."
        }
    }

    var icon: String {
        switch self {
        case .connected: return "lock.shield.fill"
        case .connecting, .enrolling: return "arrow.triangle.2.circlepath"
        case .signedOut, .cancelled: return "pause.circle"
        case .unsupportedProtocol: return "arrow.down.app"
        case .revoked: return "xmark.shield"
        default: return "wifi.exclamationmark"
        }
    }
}

// MARK: - Notifications Panel

struct NotificationsPanel: View {
    @ObservedObject var viewModel: NotchViewModel

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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                // Header row
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "bell")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("NOTIFICATIONS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        if viewModel.unreadCount > 0 {
                            Text("\(viewModel.unreadCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(DN.accent)
                        }
                    }
                    Spacer()
                    if viewModel.unreadCount > 0 {
                        Button(action: { viewModel.markAllRead() }) {
                            Text("Mark all read")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .frame(height: 20)
                                .perchGlass(in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if viewModel.notifications.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No notifications")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Scheduled task results will appear here")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                } else {
                    VStack(spacing: 10) {
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
            .padding(.vertical, 6)
        }
        .onAppear { viewModel.loadNotifications() }
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
            // Card header
            HStack(spacing: 8) {
                // Unread dot
                Circle()
                    .fill(unreadCount > 0 ? DN.accent : Color.clear)
                    .frame(width: 5, height: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: unreadCount > 0 ? .semibold : .medium))
                        .foregroundStyle(unreadCount > 0 ? Color.white : Color.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text("Scheduled")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(notifDate(latest.createdAt))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if items.count > 1 {
                    Text("\(items.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                if isExpanded, let sourceId = latest.sourceId {
                    let task = viewModel.scheduledTasks.first { $0.id == sourceId }
                    Button(action: {
                        viewModel.toggleScheduledTask(sourceId, enabled: !(task?.enabled ?? true))
                    }) {
                        Image(systemName: task?.enabled != false ? "pause.circle" : "play.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(task?.enabled != false ? DN.warning : DN.success)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        viewModel.deleteScheduledTask(sourceId)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(DN.accent)
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, isExpanded ? 8 : 12)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(DN.transition) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(items) { notif in
                        NotificationRunRow(notif: notif, viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 18)
        .animation(DN.transition, value: isExpanded)
    }
}

struct NotificationRunRow: View {
    let notif: NotificationItem
    @ObservedObject var viewModel: NotchViewModel
    @State private var showBody = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(notif.read ? Color.white.opacity(0.15) : DN.accent)
                    .frame(width: 5, height: 5)

                Text(notifDate(notif.createdAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(notif.read ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))

                Spacer()

                if notif.body != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showBody ? 90 : 0))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture {
                guard notif.body != nil else { return }
                withAnimation(DN.transition) { showBody.toggle() }
                if !notif.read { viewModel.markNotificationRead(notif.id) }
            }

            if showBody, let body = notif.body, !body.isEmpty {
                MarkdownView(text: body, isFinal: true)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .animation(DN.transition, value: showBody)
    }
}

private func notifDate(_ iso: String) -> String {
    formatRelativeDate(iso, fallbackFormat: "MMM d, h:mm a")
}

// MARK: - Settings (vanilla Apple Form + Section + native controls)
//
// Per Apple's Liquid Glass guidance: never apply glass to content. The Settings
// page is a form, so we use SwiftUI's `Form` + `Section` directly and let the
// system render every row, toggle, slider, picker, and field. Action buttons
// use `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` with
// `.tint(.clear)` on macOS where required.

struct SettingsPanel: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                section(title: "Chat") {
                    settingsToggle("Open chat on send", $viewModel.settings.openChatOnSend)
                    settingsToggle("Restore last view", $viewModel.settings.restoreLastView)
                    settingsToggle("Keep open in chat", $viewModel.settings.keepOpenInChat)
                }

                section(title: "Device Connection") {
                    deviceConnectionSection
                }

                section(title: "Billing") {
                    billingSection
                }

                section(title: "Provider") {
                    defaultProviderRow
                    ForEach(["anthropic", "openai", "openrouter"], id: \.self) { providerType in
                        Divider().background(Color.white.opacity(0.08))
                        ProviderRow(viewModel: viewModel, providerType: providerType)
                    }
                }

                section(title: "Widgets", footer: "Toggle Today widgets. Long-press a widget in Today to rearrange it.") {
                    ForEach(PinnedWidget.allCases, id: \.rawValue) { widget in
                        widgetToggleRow(widget)
                    }
                }

                section(title: "Privacy & Access") {
                    settingsToggle("Agent monitoring", $viewModel.settings.agentMonitoringEnabled)
                    settingsToggle("Music controls", $viewModel.settings.musicControlsEnabled)
                    settingsToggle("System notifications", systemNotificationsBinding)
                }

                section(title: "Agents") {
                    settingsToggle("Live activity", $viewModel.settings.showAgentLiveState)
                    settingsToggle("Compact rows", $viewModel.settings.compactAgentRows)
                }

                integrationsSection
            }
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.never)
        .smartScrollFade(28, bottomRadius: 28)
        .onAppear {
            viewModel.loadProviderConfigs()
            viewModel.loadProviderModels()
            viewModel.loadBillingStatus()
            for app in ["gmail", "googlecalendar", "googledocs", "github"] {
                viewModel.checkAppStatus(app)
            }
        }
    }

    private var systemNotificationsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.systemNotificationsEnabled },
            set: { enabled in
                viewModel.settings.systemNotificationsEnabled = enabled
                guard enabled, Bundle.main.bundleIdentifier != nil else { return }
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        guard !granted else { return }
                        DispatchQueue.main.async {
                            viewModel.settings.systemNotificationsEnabled = false
                        }
                    }
            }
        )
    }

    // MARK: - Integrations grid

    private var deviceConnectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                viewModel.connectionState.title,
                systemImage: viewModel.connectionState.icon
            )
            .font(.system(size: 12, weight: .semibold))
            Text(viewModel.connectionState.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let email = viewModel.authManager?.session?.email {
                Text("Active account: \(email)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if viewModel.connectionState.requiresUpdate {
                    Button("Check for Updates") {
                        UpdateController.shared.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                if viewModel.connectionState.canReenroll {
                    Button("Re-enroll") { viewModel.reenrollDevice() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if viewModel.connectionState.canRetry {
                    Button("Retry") { viewModel.retryDeviceConnection() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if viewModel.connectionState.canCancel {
                    Button("Cancel") { viewModel.cancelDeviceConnection() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Button("Switch Account") { viewModel.authManager?.logout() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.connectionState.announcement)
    }

    private var integrationsSection: some View {
        let apps: [(type: String, name: String, icon: String)] = [
            ("gmail",          "Gmail",    "envelope.fill"),
            ("googlecalendar", "Calendar", "calendar"),
            ("googledocs",     "Docs",     "doc.text.fill"),
            ("github",         "GitHub",   "chevron.left.forwardslash.chevron.right"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Integrations")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(apps, id: \.type) { app in
                    AppConnectionTile(
                        viewModel: viewModel,
                        appType: app.type,
                        displayName: app.name,
                        icon: app.icon
                    )
                }
            }
        }
    }

    // MARK: - Section primitives

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentCard(cornerRadius: 20)

            if let footer = footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }

    private func settingsToggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(DN.accent)
    }

    // MARK: - Billing

    private var billingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(billingTitle, systemImage: billingIcon)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                billingBadge
            }

            Text(billingSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("14-day server-funded trial · up to $5 of shared chat + scheduled usage daily · $5 lifetime app unlock · your own provider API key is mandatory after the trial.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(checkoutStateText, systemImage: checkoutStateIcon)
                .font(.caption)
                .foregroundStyle(checkoutStateColor)
                .fixedSize(horizontal: false, vertical: true)

            if let error = viewModel.billingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(DN.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Refresh") { viewModel.loadBillingStatus() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.clear)

                if viewModel.billingStatus?.canPurchase == true {
                    Button(viewModel.checkoutState.isBusy ? "Checkout pending…" : "Buy $5 lifetime") {
                        viewModel.startCheckout()
                    }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(DN.accent)
                        .disabled(viewModel.checkoutState.isBusy)
                }

                if viewModel.billingStatus?.requiresProviderKey == true
                    || viewModel.billingStatus?.hasActiveProvider == false {
                    Button("Add Provider") {
                        viewModel.requestProviderSetup()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.clear)
                }
            }

            Text("Purchases are account-based. Sign in with this same account to restore your lifetime unlock.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var checkoutStateText: String {
        switch viewModel.checkoutState {
        case .idle: return "Checkout ready."
        case .creating: return "Creating a secure checkout…"
        case .pending: return "Checkout opened. Waiting for verified payment confirmation…"
        case .success: return "Purchase confirmed for this account."
        case .timeout: return "Confirmation timed out. Your payment may still complete; refresh to check."
        case .error(let message): return message
        }
    }

    private var checkoutStateIcon: String {
        switch viewModel.checkoutState {
        case .idle: return "creditcard"
        case .creating: return "arrow.triangle.2.circlepath"
        case .pending: return "clock"
        case .success: return "checkmark.circle.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var checkoutStateColor: Color {
        switch viewModel.checkoutState {
        case .success: return DN.success
        case .timeout, .error: return DN.accent
        case .creating, .pending: return DN.warning
        case .idle: return .secondary
        }
    }

    private var billingTitle: String {
        guard let status = viewModel.billingStatus else {
            return viewModel.billingLoading ? "Loading trial status" : "Trial status"
        }
        if status.isPaid { return "Lifetime unlocked" }
        if status.canUseServerKey && status.trialUsage.dailyLimitReached {
            return "Daily limit reached"
        }
        if status.isTrialing { return "\(status.trialDaysRemaining) day trial left" }
        return "Trial ended"
    }

    private var billingSubtitle: String {
        guard let status = viewModel.billingStatus else {
            return "Perch checks trial and purchase status on the backend."
        }
        if status.canUseServerKey && status.trialUsage.dailyLimitReached {
            let reset = status.trialUsage.resetDate?.formatted(date: .omitted, time: .shortened)
                ?? "tomorrow"
            return "Chat and scheduled tasks resume automatically at \(reset). You can still pause or resume schedules."
        }
        if status.hasActiveProvider {
            return "Using your \(status.activeProvider ?? "provider") key for chat and scheduled tasks."
        }
        if status.canUseServerKey {
            return "Using the server Anthropic key with a shared $5 daily chat and scheduled-task allowance."
        }
        if status.requiresPurchase {
            return "Buy once to unlock the app, then add your own provider key to continue."
        }
        if status.requiresProviderKey {
            return "Add or activate a provider key below to continue using chat and scheduled tasks."
        }
        return "Billing status is active."
    }

    private var billingIcon: String {
        guard let status = viewModel.billingStatus else { return "hourglass" }
        if status.isPaid { return "checkmark.seal.fill" }
        if status.isTrialing { return "timer" }
        return "exclamationmark.triangle.fill"
    }

    private var billingBadge: some View {
        let label: String
        let color: Color
        if let status = viewModel.billingStatus {
            if status.isPaid {
                label = "PAID"
                color = DN.success
            } else if status.isTrialing {
                label = "TRIAL"
                color = DN.warning
            } else {
                label = "EXPIRED"
                color = DN.accent
            }
        } else {
            label = viewModel.billingLoading ? "LOADING" : "UNKNOWN"
            color = DN.textSecondary
        }

        return Text(label)
            .font(DN.label(9))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Default provider row

    private var defaultProviderRow: some View {
        let isUsingDefault = !viewModel.providerConfigs.contains { $0.isActive }
        let serverKeyAllowed = viewModel.billingStatus?.canUseServerKey ?? true
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Label("Trial Default", systemImage: "server.rack")
                Text(serverKeyAllowed ? "Server Anthropic key during trial" : "Requires active BYOK provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isUsingDefault {
                Text(serverKeyAllowed ? "Active" : "Locked")
                    .foregroundStyle(serverKeyAllowed ? .green : DN.accent)
                    .font(.callout)
            } else {
                if serverKeyAllowed {
                    Button("Use") { viewModel.deactivateAllProviders() }
                        .buttonStyle(.bordered).controlSize(.small).tint(.clear)
                } else {
                    Text("Trial ended")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Widget toggle row

    @ViewBuilder
    private func widgetToggleRow(_ widget: PinnedWidget) -> some View {
        let isPinned = viewModel.settings.pinnedWidgets.contains(widget)
        Toggle(isOn: Binding(
            get: { isPinned },
            set: { newValue in
                withAnimation(DN.transition) {
                    if newValue {
                        if !viewModel.settings.pinnedWidgets.contains(widget) {
                            viewModel.settings.pinnedWidgets.append(widget)
                        }
                    } else {
                        viewModel.settings.pinnedWidgets.removeAll { $0 == widget }
                    }
                }
            }
        )) {
            Label(widget.label, systemImage: widget.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(DN.accent)
    }
}

// MARK: - Provider row (BYOK)

struct ProviderRow: View {
    @ObservedObject var viewModel: NotchViewModel
    let providerType: String

    @State private var isExpanded = false
    @State private var apiKey = ""
    @State private var modelId = ""

    private var config: ProviderConfig? {
        viewModel.providerConfigs.first { $0.provider == providerType }
    }
    private var isActive: Bool { config?.isActive ?? false }
    private var isConfigured: Bool { config != nil }
    private var isVerifying: Bool { viewModel.providerVerifying[providerType] ?? false }
    private var isVerified: Bool {
        (viewModel.providerVerified[providerType] ?? false) || (config?.isVerified ?? false)
    }
    private var error: String? { viewModel.providerError[providerType] ?? nil }

    private var displayName: String {
        config?.displayName ?? ProviderConfig(
            id: "", provider: providerType, modelId: "", isActive: false
        ).displayName
    }

    private var icon: String {
        config?.icon ?? ProviderConfig(
            id: "", provider: providerType, modelId: "", isActive: false
        ).icon
    }

    private var defaultModel: String {
        ProviderConfig.defaultModels[providerType] ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row — tappable to toggle expansion.
            HStack {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Label(displayName, systemImage: icon)
                Spacer()
                if isActive {
                    Text("Active")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else if isConfigured {
                    Text(config?.modelId ?? "")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Use") {
                        viewModel.activateProviderConfig(provider: providerType)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.clear)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(DN.transition) {
                    isExpanded.toggle()
                    if isExpanded && modelId.isEmpty {
                        modelId = config?.modelId ?? defaultModel
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("API key", text: $apiKey)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .perchGlass(in: Capsule())

                    Picker("Model", selection: Binding(
                        get: { modelId.isEmpty ? defaultModel : modelId },
                        set: { modelId = $0 }
                    )) {
                        ForEach(ProviderConfig.availableModels[providerType] ?? [], id: \.id) { m in
                            Text(m.label).tag(m.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Button(isVerifying ? "Verifying…" : (isVerified && apiKey.isEmpty ? "Verified" : "Verify")) {
                            guard !apiKey.isEmpty else { return }
                            let model = modelId.isEmpty ? defaultModel : modelId
                            viewModel.verifyProviderKey(provider: providerType, apiKey: apiKey, modelId: model)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.clear)
                        .disabled(apiKey.isEmpty || isVerifying)

                        Button("Save") {
                            guard !apiKey.isEmpty else { return }
                            let model = modelId.isEmpty ? defaultModel : modelId
                            viewModel.saveProviderConfig(provider: providerType, apiKey: apiKey, modelId: model)
                            apiKey = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(DN.activeAccent)
                        .foregroundStyle(.white)
                        .disabled(apiKey.isEmpty)

                        Spacer()

                        if isConfigured {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteProviderConfig(provider: providerType)
                                apiKey = ""
                                modelId = defaultModel
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.clear)
                        }
                    }

                    if let error = error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 22)
                .transition(.opacity)
                .onAppear {
                    if modelId.isEmpty { modelId = config?.modelId ?? defaultModel }
                }
            }
        }
        .onAppear {
            if viewModel.requestedProviderType == providerType {
                isExpanded = true
                modelId = config?.modelId ?? defaultModel
            }
        }
        .onChange(of: viewModel.requestedProviderType) { _, requested in
            guard requested == providerType else { return }
            withAnimation(DN.transition) {
                isExpanded = true
                modelId = config?.modelId ?? defaultModel
            }
        }
    }
}

// MARK: - App connection tile (OAuth grid cell)

struct AppConnectionTile: View {
    @ObservedObject var viewModel: NotchViewModel
    let appType: String
    let displayName: String
    let icon: String

    @State private var isHovering = false

    private var isConnected: Bool { viewModel.appConnected[appType] ?? false }
    private var isLoading: Bool { viewModel.appLoading[appType] ?? false }
    private var error: String? { viewModel.appError[appType] ?? nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Icon + status dot
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isConnected ? Color.white : Color.secondary)
                Spacer()
                statusDot
            }
            .padding(.bottom, 8)

            // Name
            Text(displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isConnected ? Color.white : Color.secondary)
                .lineLimit(1)

            Spacer(minLength: 6)

            // Action button
            actionButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .perchGlass(
            tint: isConnected
                ? Color.green.opacity(0.15)
                : (error != nil ? Color.orange.opacity(0.12) : nil),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .animation(DN.transition, value: isConnected)
        .animation(DN.transition, value: isLoading)
    }

    @ViewBuilder
    private var statusDot: some View {
        if isLoading {
            ProgressView().controlSize(.mini).tint(.white)
        } else if isConnected {
            Circle().fill(Color.green).frame(width: 7, height: 7)
        } else if error != nil {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if isLoading {
            Text("Connecting…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        } else if isConnected {
            Button("Disconnect") { viewModel.disconnectApp(appType) }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .perchGlass(in: Capsule())
                .buttonStyle(.plain)
        } else {
            Button(error != nil ? "Retry" : "Connect") {
                viewModel.resetApp(appType)
                viewModel.connectApp(appType)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .perchGlass(
                tint: error != nil ? Color.orange.opacity(0.4) : DN.activeAccent,
                in: Capsule()
            )
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Notch blur background (NSVisualEffectView wrapper)
//
// Using NSVisualEffectView instead of glassEffect on the root shape avoids
// the EXC_BREAKPOINT crash caused by applying glassEffect inside a
// compositingGroup during CA transaction commits on macOS 26.

private struct NotchBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Color hex helper

private extension Color {
    func toHexString() -> String {
        #if os(macOS)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return "#FFFFFF"
        #endif
    }
}
