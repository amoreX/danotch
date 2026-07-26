import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        Group {
            switch viewModel.viewState {
            case .overview:
                TodayPage(viewModel: viewModel)
            case .taskList:
                AgentsPage(viewModel: viewModel)
            case .agentChat(let taskId):
                AgentChatView(viewModel: viewModel, taskId: taskId)
            case .agents:
                AgentsPage(viewModel: viewModel)
            case .stats, .processList, .settings, .notifications:
                EmptyView()
            }
        }
    }
}

// MARK: - Today Page

private struct TodayPage: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var composerText: String = ""
    @FocusState private var composerFocused: Bool

    @State private var draggingWidget: PinnedWidget? = nil
    @State private var dragLocation: CGPoint? = nil
    @State private var dragGrabOffset: CGSize = .zero
    @State private var widgetFrames: [PinnedWidget: CGRect] = [:]
    @State private var dragStartFrames: [PinnedWidget: CGRect] = [:]
    @State private var dragStartOrder: [PinnedWidget] = []
    @State private var isEditMode: Bool = false

    // Approximate height available for the widget grid before scrolling kicks in.
    // Panel expanded height is 320px. Clock card (72+10) + composer (46+10) + padding (4+10) = 152px.
    private static let widgetVisibleH: CGFloat = 168

    private let statsTypes: [PinnedWidget] = [.ram, .disk, .network, .uptime, .processes]
    private let spacing: CGFloat = 10

    private var pinned: [PinnedWidget] { viewModel.settings.pinnedWidgets }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: spacing) {
                TodayClockCard(viewModel: viewModel, isEditMode: $isEditMode)
                    .frame(height: 80)

                widgetGrid

                if !isEditMode {
                    composer
                }
            }
            .padding(.bottom, 4)
        }
        .scrollIndicators(.never)
        .scrollDisabled(draggingWidget != nil)
        .smartScrollFade(40, bottomRadius: 28)
        .frame(maxWidth: .infinity, alignment: .top)
        .onChange(of: viewModel.shouldFocusChatInput) { _, v in
            if v { composerFocused = true; viewModel.shouldFocusChatInput = false }
        }
        .onChange(of: composerFocused) { _, f in viewModel.isChatInputActive = f }
        .onChange(of: isEditMode) { _, editing in
            if editing { composerFocused = false }
            if !editing { cancelDrag(animated: false) }
        }
        .onDisappear {
            cancelDrag(animated: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .perchWidgetDragRecoveryRequested)) { _ in
            guard draggingWidget != nil else { return }
            cancelDrag(animated: false)
        }
    }

    // MARK: - Widget grid

    private var widgetGrid: some View {
        VStack(spacing: spacing) {
            ForEach(widgetRows.indices, id: \.self) { rowIndex in
                let row = widgetRows[rowIndex]

                if row.count == 1, let widget = row.first {
                    widgetGridCell(widget)
                        .frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(row, id: \.self) { widget in
                            widgetGridCell(widget)
                        }
                    }
                }
            }

            if isEditMode {
                addWidgetHint
            }
        }
        .coordinateSpace(name: WidgetGridLayout.coordinateSpaceName)
        .overlay(alignment: .topLeading) {
            floatingWidget
        }
        .onPreferenceChange(WidgetFramePreferenceKey.self) { frames in
            // Preference delivery can occur repeatedly while SwiftUI lays out
            // an animated overlay. Do not feed those transient frames back
            // into the active gesture or trigger a redundant render cycle.
            guard draggingWidget == nil, frames != widgetFrames else { return }
            widgetFrames = frames
        }
        .animation(DN.transition, value: pinned)
        .animation(DN.transition, value: isEditMode)
    }

    private var addWidgetHint: some View {
        HStack(spacing: 5) {
            Image(systemName: "plus.circle")
                .font(.system(size: 10))
            Text("Add widgets in Settings → Widgets")
                .font(.system(size: 10))
        }
        .foregroundStyle(Color.white.opacity(0.3))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var widgetRows: [[PinnedWidget]] {
        var rows: [[PinnedWidget]] = []
        var i = 0
        while i < pinned.count {
            let w = pinned[i]
            if viewModel.settings.widgetIsFullWidth(w) {
                rows.append([w])
                i += 1
            } else if i + 1 < pinned.count && !viewModel.settings.widgetIsFullWidth(pinned[i + 1]) {
                rows.append([w, pinned[i + 1]])
                i += 2
            } else {
                rows.append([w])
                i += 1
            }
        }
        return rows
    }

    private func widgetGridCell(_ widget: PinnedWidget) -> some View {
        let isDragging = draggingWidget == widget
        let base = widgetCard(widget)
            .frame(maxWidth: .infinity)
            .frame(height: widget.gridHeight)
            .opacity(isDragging ? 0.18 : 1)
            .scaleEffect(isDragging ? 0.96 : 1)
            .overlay(alignment: .topTrailing) {
                if isEditMode {
                    editModeHandleOverlay(widget)
                        // Keep the view that owns the active gesture mounted
                        // until mouse-up. Removing it here cancels the gesture
                        // before SwiftUI can deliver onEnded.
                        .opacity(isDragging ? 0 : 1)
                }
            }
            .overlay {
                if isEditMode && !isDragging {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: WidgetFramePreferenceKey.self,
                        value: [widget: proxy.frame(in: .named(WidgetGridLayout.coordinateSpaceName))]
                    )
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .animation(DN.transition, value: draggingWidget)
            .animation(DN.transition, value: isEditMode)
        return applyDragGesture(to: base, widget: widget)
    }

    private func editModeHandleOverlay(_ widget: PinnedWidget) -> some View {
        HStack(spacing: 4) {
            // Resize toggle: full-width ↔ half-width
            Button(action: {
                withAnimation(DN.transition) {
                    viewModel.settings.toggleWidgetSize(widget)
                }
            }) {
                Image(systemName: viewModel.settings.widgetIsFullWidth(widget) ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Drag handle indicator
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 20, height: 20)
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
                .contentShape(Circle())
                .gesture(editModeDragGesture(for: widget))
        }
        .padding(8)
    }

    @ViewBuilder
    private var floatingWidget: some View {
        if let widget = draggingWidget,
           let location = dragLocation,
           let frame = dragStartFrames[widget] {
            let position = CGPoint(
                x: location.x - dragGrabOffset.width,
                y: location.y - dragGrabOffset.height
            )

            widgetCard(widget)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(1.03)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
                .position(position)
                .allowsHitTesting(false)
                .zIndex(100)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private func widgetCard(_ widget: PinnedWidget) -> some View {
        if statsTypes.contains(widget) {
            TodayStatsRow(stats: viewModel.statsMonitor, widgets: [widget])
        } else {
            widgetContent(widget)
        }
    }

    private func applyDragGesture(to view: some View, widget: PinnedWidget) -> some View {
        if isEditMode {
            // In edit mode only the dedicated handle starts a drag. Attaching
            // the gesture to the whole card also attaches it to the resize
            // button, allowing one mouse-up to resize and reorder concurrently.
            return AnyView(view)
        } else {
            return AnyView(view.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.28, maximumDistance: 8)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(WidgetGridLayout.coordinateSpaceName)))
                    .onChanged { value in
                        switch value {
                        case .second(true, let drag?):
                            updateDrag(widget: widget, value: drag)
                        default:
                            break
                        }
                    }
                    .onEnded { value in
                        switch value {
                        case .second(true, let drag?):
                            finishDrag(widget: widget, at: drag.location)
                        default:
                            cancelDrag()
                        }
                    }
            ))
        }
    }

    private func editModeDragGesture(for widget: PinnedWidget) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(WidgetGridLayout.coordinateSpaceName))
            .onChanged { value in updateDrag(widget: widget, value: value) }
            .onEnded { value in
                finishDrag(widget: widget, at: value.location)
            }
    }

    private func updateDrag(widget: PinnedWidget, value: DragGesture.Value) {
        guard draggingWidget == nil || draggingWidget == widget,
              value.location.x.isFinite,
              value.location.y.isFinite else { return }

        if draggingWidget == nil {
            guard let frame = widgetFrames[widget],
                  frame.width > 0,
                  frame.height > 0,
                  !frame.isNull,
                  !frame.isInfinite else { return }
            dragStartFrames = widgetFrames
            dragStartOrder = viewModel.settings.pinnedWidgets
            dragGrabOffset = CGSize(
                width: value.startLocation.x - frame.midX,
                height: value.startLocation.y - frame.midY
            )
            viewModel.isDraggingWidget = true
            withAnimation(DN.transition) {
                draggingWidget = widget
            }
        }

        dragLocation = value.location
    }

    private func reorderedWidgets(_ widget: PinnedWidget, at location: CGPoint) -> [PinnedWidget]? {
        guard location.x.isFinite, location.y.isFinite else { return nil }
        let current = dragStartOrder
        guard let from = current.firstIndex(of: widget) else { return nil }

        let itemFrames = current.enumerated().compactMap { index, widget in
            dragStartFrames[widget].map { WidgetGridItemFrame(index: index, frame: $0) }
        }
        guard itemFrames.count == current.count else { return nil }
        guard let target = WidgetGridLayout.targetIndex(at: location, in: itemFrames),
              target != from else { return nil }

        return WidgetGridLayout.reorder(current, movingFrom: from, to: target)
    }

    private func finishDrag(widget: PinnedWidget, at location: CGPoint) {
        let originalOrder = dragStartOrder
        let reordered = reorderedWidgets(widget, at: location)
        cancelDrag(animated: false)

        guard let reordered else { return }
        // Let SwiftUI tear down the gesture and floating overlay before
        // changing ForEach structure. This avoids an AttributeGraph update
        // cycle when a widget moves between one- and two-column rows.
        DispatchQueue.main.async {
            guard viewModel.settings.pinnedWidgets == originalOrder else { return }
            withAnimation(DN.transition) {
                viewModel.settings.pinnedWidgets = reordered
            }
        }
    }

    private func cancelDrag(animated: Bool = true) {
        viewModel.isDraggingWidget = false
        let reset = {
            draggingWidget = nil
            dragLocation = nil
            dragGrabOffset = .zero
            dragStartFrames = [:]
            dragStartOrder = []
        }
        if animated {
            withAnimation(DN.transition) {
                reset()
            }
        } else {
            reset()
        }
    }

    // MARK: - Widget content

    @ViewBuilder
    private func widgetContent(_ widget: PinnedWidget) -> some View {
        switch widget {
        case .music:          TodayMusicCard(monitor: viewModel.nowPlaying)
        case .calendar:       TodayInlineCalendarCard()
        case .scheduledTasks: ScheduledTasksTodayCard(viewModel: viewModel)
        default:              EmptyView()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            ChatModelSelectorView(viewModel: viewModel)

            TextField(
                "Ask Perch anything…",
                text: $composerText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .focused($composerFocused)
                .onSubmit { submit() }
                .contentShape(Rectangle())
                .onTapGesture { composerFocused = true }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            sendButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .perchGlass(in: Capsule())
        .contentShape(Rectangle())
        // `simultaneousGesture` (not `.onTapGesture`) so this still fires even
        // though the TextField above already claims its own tap — otherwise
        // only the placeholder/text glyphs were focusable, not the rest of
        // the field's padded width or the empty capsule area around it.
        .simultaneousGesture(TapGesture().onEnded {
            composerFocused = true
        })
    }

    private var sendButton: some View {
        let enabled = !composerText.trimmingCharacters(in: .whitespaces).isEmpty
        return Image(systemName: "arrow.up")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .perchGlass(tint: enabled ? DN.activeAccent : nil, in: Circle())
            .opacity(enabled ? 1 : 0.55)
            .contentShape(.circle)
            .onTapGesture { if enabled { submit() } }
    }

    private func submit() {
        let trimmed = composerText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        composerText = ""
        composerFocused = false
        viewModel.sendChat(message: trimmed)
    }
}

private struct WidgetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [PinnedWidget: CGRect] = [:]

    static func reduce(value: inout [PinnedWidget: CGRect], nextValue: () -> [PinnedWidget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Today modules

private struct TodayClockCard: View {
    @ObservedObject var viewModel: NotchViewModel
    @Binding var isEditMode: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(viewModel.timeString)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .tracking(-1.2)
                Text(viewModel.periodString)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(viewModel.dateString)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if isEditMode {
                        resetLayoutButton
                    }
                    editButton
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCell(cornerRadius: 18)
    }

    private var editButton: some View {
        Button(action: { withAnimation(DN.transition) { isEditMode.toggle() } }) {
            HStack(spacing: 3) {
                Image(systemName: isEditMode ? "checkmark" : "square.grid.2x2")
                    .font(.system(size: 8, weight: .semibold))
                Text(isEditMode ? "Done" : "Edit")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(isEditMode ? DN.success : Color.white.opacity(0.4))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isEditMode ? DN.success.opacity(0.18) : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    private var resetLayoutButton: some View {
        Button {
            let selected = Set(viewModel.settings.pinnedWidgets)
            let defaultOrder = PinnedWidget.allCases.filter { selected.contains($0) }
            withAnimation(DN.transition) {
                viewModel.settings.widgetSizes = [:]
                viewModel.settings.pinnedWidgets = defaultOrder
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8, weight: .semibold))
                Text("Reset")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .help("Reset widget order and sizes")
    }
}

private struct TodayMusicCard: View {
    @ObservedObject var monitor: NowPlayingMonitor

    var body: some View {
        Group {
            if let track = monitor.track {
                activeBody(track: track)
            } else {
                emptyBody
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 18)
        .animation(.easeOut(duration: 0.22), value: monitor.track)
    }

    @ViewBuilder
    private func activeBody(track: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            artwork(size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(track)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let artist = monitor.artist {
                    Text(artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: max(2, geo.size.width * monitor.progress))
                    }
                }
                .frame(height: 3)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transportControls
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            mediaButton("backward.fill", size: 12) { monitor.runCommand("previous track") }
            mediaButton(monitor.isPlaying ? "pause.fill" : "play.fill", size: 16) { monitor.runCommand("playpause") }
            mediaButton("forward.fill", size: 12) { monitor.runCommand("next track") }
        }
    }

    private var emptyBody: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("Nothing playing")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Start a track in Apple Music or Spotify")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack {
            if let img = monitor.artworkImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func mediaButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size + 12, height: size + 12)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scheduled Tasks Today Card

private struct ScheduledTasksTodayCard: View {
    @ObservedObject var viewModel: NotchViewModel

    private var enabled: [ScheduledTask] { viewModel.scheduledTasks.filter { $0.enabled }.prefix(4).map { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(DN.warning)
                Text("SCHEDULED")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.scheduledTasks.filter { $0.enabled }.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if enabled.isEmpty {
                Text("No active tasks")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(enabled) { task in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(task.lastStatus == "failed" ? DN.accent : DN.warning)
                                .frame(width: 4, height: 4)
                            Text(task.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Text(task.scheduleHuman)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 16)
        .onAppear { viewModel.loadScheduledTasks() }
    }
}

// MARK: - Today stats row (widget-driven)

private struct TodayStatsRow: View {
    @ObservedObject var stats: SystemStatsMonitor
    let widgets: [PinnedWidget]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(widgets, id: \.rawValue) { widget in
                tile(for: widget)
            }
        }
    }

    @ViewBuilder
    private func tile(for widget: PinnedWidget) -> some View {
        switch widget {
        case .ram:
            TodayStatTile(icon: "memorychip", label: "RAM",
                          value: "\(Int(stats.ramPercent))%",
                          progress: stats.ramPercent / 100,
                          tint: tint(for: stats.ramPercent))
        case .disk:
            TodayStatTile(icon: "internaldrive", label: "DISK",
                          value: "\(Int(stats.diskPercent))%",
                          progress: stats.diskPercent / 100,
                          tint: tint(for: stats.diskPercent))
        case .network:
            TodayNetworkTile(stats: stats)
        case .uptime:
            TodayStatTile(icon: "clock", label: "UPTIME",
                          value: stats.uptimeString,
                          progress: 0, tint: .cyan)
        case .processes:
            TodayStatTile(icon: "list.number", label: "PROCS",
                          value: "\(stats.processCount)",
                          progress: 0, tint: .purple)
        default:
            EmptyView()
        }
    }

    private func tint(for pct: Double) -> Color {
        if pct > 85 { return .red }
        if pct > 65 { return .yellow }
        return .green
    }
}

private struct TodayInlineCalendarCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("CALENDAR")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
            MiniCalendarView(compact: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCell(cornerRadius: 16)
    }
}

private struct TodayNetworkTile: View {
    @ObservedObject var stats: SystemStatsMonitor

    private func fmt(_ bytes: Double) -> String {
        if bytes > 1_000_000 { return String(format: "%.1fM", bytes / 1_000_000) }
        if bytes > 1_000 { return String(format: "%.0fK", bytes / 1_000) }
        return "0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("NET")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up").font(.system(size: 8))
                Text(fmt(stats.netUp)).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.white)
            HStack(spacing: 4) {
                Image(systemName: "arrow.down").font(.system(size: 8))
                Text(fmt(stats.netDown)).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 16)
    }
}

private struct TodayStatTile: View {
    let icon: String
    let label: String
    let value: String
    let progress: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer(minLength: 0)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(tint.opacity(0.9))
                        .frame(width: max(2, geo.size.width * max(0, min(1, progress))))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 16)
    }
}



// MARK: - Icon Action Button (icon only, label on hover)

struct IconActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.clear)
        .help(label)
    }
}

// MARK: - Agent Group View

struct AgentGroupView: View {
    let group: AgentGroup
    let isCompact: Bool
    @Binding var collapsedGroups: Set<String>
    var showLiveState: Bool = true
    let onTapAgent: (DetectedAgent) -> Void

    private var isGroupExpanded: Bool { !collapsedGroups.contains(group.id) }
    private var canCollapse: Bool { group.agents.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header — tappable to toggle if multiple agents
            Button(action: {
                guard canCollapse else { return }
                withAnimation(DN.transition) {
                    collapsedGroups.toggle(group.id)
                }
            }) {
                HStack(spacing: DN.spaceSM) {
                    Image(systemName: group.type.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(group.type.brandColor)
                        .frame(width: 14)

                    Text(group.type.rawValue)
                        .font(DN.body(11, weight: .semibold))
                        .foregroundColor(group.type.brandColor)

                    if group.agents.count > 1 {
                        Text("\(group.agents.count)")
                            .font(DN.mono(10, weight: .medium))
                            .foregroundColor(group.type.brandColor.opacity(0.7))
                    }

                    Spacer()

                    ActiveBadge(count: group.runningCount)

                    if canCollapse {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DN.textDisabled)
                            .rotationEffect(.degrees(isGroupExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, DN.spaceMD)
                .padding(.vertical, DN.spaceSM)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Agent rows — collapsible
            if isGroupExpanded {
                VStack(spacing: 1) {
                    ForEach(group.agents) { agent in
                        AgentSessionRow(agent: agent, showLiveState: showLiveState, isCompact: isCompact) {
                            onTapAgent(agent)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentCard(cornerRadius: DN.radiusMD)
    }
}

// MARK: - Agent Session Row (individual session within a group)

struct AgentSessionRow: View {
    let agent: DetectedAgent
    var showLiveState: Bool = true
    let isCompact: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DN.spaceSM) {
                    // Project name — primary identifier
                    Text(agent.displayName)
                        .font(DN.body(12, weight: .semibold))
                        .foregroundColor(DN.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Elapsed
                    Text(agent.elapsed)
                        .font(DN.mono(10))
                        .foregroundColor(DN.textDisabled)
                }

                // Live state indicator
                if showLiveState && agent.liveState != .idle && agent.liveState != .waitingForUser {
                    LiveStateView(state: agent.liveState, detail: agent.liveDetail)
                        .padding(.top, 1)
                }

                // Last prompt
                if let prompt = agent.lastPrompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(DN.body(10))
                        .foregroundColor(agent.liveState == .waitingForUser || agent.liveState == .idle ? DN.textDisabled : DN.textSecondary)
                        .lineLimit(isCompact ? 1 : 2)
                }

                // Resource usage on hover or expanded
                if isHovering || !isCompact {
                    HStack(spacing: DN.spaceSM) {
                        HStack(spacing: 3) {
                            Text("CPU")
                                .font(DN.label(9))
                                .tracking(0.5)
                                .foregroundColor(DN.textDisabled)
                            Text(String(format: "%.1f%%", agent.cpu))
                                .font(DN.mono(10))
                                .foregroundColor(agent.cpu > 1.0 ? DN.warning : DN.textSecondary)
                        }

                        HStack(spacing: 3) {
                            Text("MEM")
                                .font(DN.label(9))
                                .tracking(0.5)
                                .foregroundColor(DN.textDisabled)
                            Text(String(format: "%.0fMB", agent.memMB))
                                .font(DN.mono(10))
                                .foregroundColor(DN.textSecondary)
                        }

                        Spacer()
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, DN.spaceSM)
            .padding(.vertical, DN.spaceXS + 2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DN.radiusSM, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
            )
            .animation(DN.transition, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Live State View

struct LiveStateView: View {
    let state: AgentLiveState
    let detail: String?
    @State private var pulse = false

    init(state: AgentLiveState, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: DN.spaceXS) {
                Circle()
                    .fill(state.color)
                    .frame(width: 4, height: 4)
                    .opacity(pulse ? 1.0 : 0.4)

                Image(systemName: state.icon)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(state.color)

                Text(state.label)
                    .font(DN.label(8))
                    .tracking(0.6)
                    .foregroundColor(state.color)
            }

            if let detail = detail, !detail.isEmpty {
                Text(detail)
                    .font(DN.mono(9))
                    .foregroundColor(state.color.opacity(0.6))
                    .lineLimit(1)
                    .padding(.leading, 12)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Agent Row (for WebSocket tasks)

struct AgentRow: View {
    let task: SubagentTask
    let isCompact: Bool
    let activityText: String
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DN.spaceSM) {
                    Circle()
                        .fill(DN.statusColor(task.status))
                        .frame(width: 6, height: 6)

                    Text(task.description ?? task.task)
                        .font(DN.body(12, weight: .medium))
                        .foregroundColor(DN.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(task.durationString)
                        .font(DN.mono(10))
                        .foregroundColor(DN.textDisabled)
                }

                if task.status == .running && (!isCompact || isHovering) {
                    ActivityText(text: activityText, color: DN.warning)
                        .padding(.leading, 14)
                        .padding(.top, 3)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, DN.spaceSM)
            .padding(.vertical, isCompact ? 6 : 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DN.radiusSM, style: .continuous)
                    .fill(isHovering ? Color.white.opacity(0.06) : Color.clear)
            )
            .animation(DN.transition, value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Activity Text

struct ActivityText: View {
    let text: String
    let color: Color
    @State private var phase: Bool = false

    var body: some View {
        HStack(spacing: DN.spaceXS) {
            HStack(spacing: 2) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(color.opacity(dotOpacity(i)))
                        .frame(width: 3, height: 3)
                }
            }

            Text(text)
                .font(DN.mono(10))
                .foregroundColor(color.opacity(0.7))
                .lineLimit(1)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                phase.toggle()
            }
        }
        .id(text)
    }

    private func dotOpacity(_ index: Int) -> Double {
        let base = phase ? 1.0 : 0.3
        switch index {
        case 0: return phase ? 1.0 : 0.3
        case 1: return 0.6
        case 2: return phase ? 0.3 : 1.0
        default: return base
        }
    }
}

// MARK: - Now Playing

enum MusicSource: String {
    case appleMusic
    case spotify

    var appName: String {
        switch self {
        case .appleMusic: return "Music"
        case .spotify:    return "Spotify"
        }
    }

    var displayName: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify:    return "Spotify"
        }
    }
}

class NowPlayingMonitor: ObservableObject {
    @Published var track: String?
    @Published var artist: String?
    @Published var isPlaying = false
    @Published var artworkImage: NSImage?
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var source: MusicSource?

    private var timer: Timer?
    private var lastTrackKey: String?
    private let pollLock = NSLock()
    private var pollInFlight = false
    private static let artPath = "/tmp/perch_art.png"

    var progress: Double { duration > 0 ? position / duration : 0 }

    func timeString(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    init(enabled: Bool = true) {
        if enabled {
            start()
        }
    }

    deinit { timer?.invalidate() }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        source = nil
        track = nil
        artist = nil
        isPlaying = false
        position = 0
        duration = 0
        artworkImage = nil
        lastTrackKey = nil
    }

    /// Send a transport command to the currently-active source. We resolve the
    /// app at call time rather than at construction so switching from Apple
    /// Music to Spotify (or vice versa) works without re-instantiating.
    func runCommand(_ cmd: String) {
        guard let src = source else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let script = """
            try
                if application "\(src.appName)" is running then
                    tell application "\(src.appName)" to \(cmd)
                end if
            end try
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.3)
            self?.poll()
        }
    }

    func poll() {
        pollLock.lock()
        guard !pollInFlight else {
            pollLock.unlock()
            return
        }
        pollInFlight = true
        pollLock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer {
                self.pollLock.lock()
                self.pollInFlight = false
                self.pollLock.unlock()
            }
            // Cheap native check first (NSWorkspace, no subprocess) — most of the
            // time neither app is running, so this avoids two osascript spawns
            // every 2 seconds forever. Each osascript spawn is heavier than a
            // plain subprocess (loads the AppleScript component) and was, along
            // with AgentMonitor's old `ps` polling, part of what hammered
            // syspolicyd/launchservicesd and caused system-wide input lag.
            let running = NSWorkspace.shared.runningApplications
            let musicRunning = running.contains { $0.bundleIdentifier == "com.apple.Music" }
            let spotifyRunning = running.contains { $0.bundleIdentifier == "com.spotify.client" }

            guard musicRunning || spotifyRunning else {
                DispatchQueue.main.async {
                    guard self.timer != nil else { return }
                    guard self.track != nil || self.source != nil else { return }
                    self.source = nil
                    self.track = nil
                    self.artist = nil
                    self.isPlaying = false
                    self.artworkImage = nil
                    self.lastTrackKey = nil
                }
                return
            }

            // Query both apps; pick whichever is actively playing. If neither
            // is playing we fall back to whichever has a track loaded (paused).
            let music = musicRunning ? Self.fetch(.appleMusic) : .empty
            let spotify = spotifyRunning ? Self.fetch(.spotify) : .empty
            let chosen = Self.pick(music: music, spotify: spotify)

            let trackKey = chosen.result.track.map { "\(chosen.source?.rawValue ?? "_")|\($0)" }
            let trackChanged = trackKey != self.lastTrackKey
            var artwork: NSImage? = self.artworkImage

            if trackChanged, let src = chosen.source, chosen.result.track != nil {
                artwork = Self.fetchArtwork(for: src, artworkURL: chosen.result.artworkURL)
            }
            if chosen.result.track == nil { artwork = nil }

            DispatchQueue.main.async {
                guard self.timer != nil else { return }
                self.source = chosen.source
                self.track = chosen.result.track
                self.artist = chosen.result.artist
                self.isPlaying = chosen.result.playing
                self.position = chosen.result.position
                self.duration = chosen.result.duration
                self.lastTrackKey = trackKey
                if trackChanged { self.artworkImage = artwork }
            }
        }
    }

    // MARK: - Source resolution

    private static func pick(
        music: FetchResult,
        spotify: FetchResult
    ) -> (source: MusicSource?, result: FetchResult) {
        // Prefer whichever app is currently playing.
        if music.playing { return (.appleMusic, music) }
        if spotify.playing { return (.spotify, spotify) }
        // Neither is playing — surface whichever has a paused track.
        if music.track != nil { return (.appleMusic, music) }
        if spotify.track != nil { return (.spotify, spotify) }
        return (nil, FetchResult.empty)
    }

    // MARK: - Per-app fetch

    private struct FetchResult {
        let track: String?
        let artist: String?
        let playing: Bool
        let position: Double
        let duration: Double
        let artworkURL: String?

        static let empty = FetchResult(track: nil, artist: nil, playing: false, position: 0, duration: 0, artworkURL: nil)
    }

    private static func fetch(_ source: MusicSource) -> FetchResult {
        switch source {
        case .appleMusic: return fetchAppleMusic()
        case .spotify:    return fetchSpotify()
        }
    }

    private static func fetchAppleMusic() -> FetchResult {
        let script = """
        try
            if application "Music" is running then
                tell application "Music"
                    if player state is playing or player state is paused then
                        set t to name of current track
                        set a to artist of current track
                        set p to player position
                        set d to duration of current track
                        set s to "paused"
                        if player state is playing then set s to "playing"
                        return t & "|||" & a & "|||" & s & "|||" & (round p) & "|||" & (round d)
                    end if
                end tell
            end if
        end try
        return ""
        """
        return parseTriplePipe(runOsa(script))
    }

    /// Spotify exposes the same dictionary verbs as iTunes/Music, plus an
    /// `artwork url` of the album artwork on Spotify's CDN — much faster to
    /// fetch via HTTP than to round-trip `raw data of artwork` through
    /// osascript. Spotify reports `duration` in MILLISECONDS, so we
    /// normalise to seconds here.
    private static func fetchSpotify() -> FetchResult {
        let script = """
        try
            if application "Spotify" is running then
                tell application "Spotify"
                    if player state is playing or player state is paused then
                        set t to name of current track
                        set a to artist of current track
                        set p to player position
                        set d to duration of current track
                        set u to ""
                        try
                            set u to artwork url of current track
                        end try
                        set s to "paused"
                        if player state is playing then set s to "playing"
                        return t & "|||" & a & "|||" & s & "|||" & (round p) & "|||" & d & "|||" & u
                    end if
                end tell
            end if
        end try
        return ""
        """
        let out = runOsa(script)
        let parts = out.components(separatedBy: "|||")
        guard parts.count >= 5, !parts[0].isEmpty else { return .empty }
        let durationMs = Double(parts[4]) ?? 0
        return FetchResult(
            track: parts[0],
            artist: parts[1],
            playing: parts[2] == "playing",
            position: Double(parts[3]) ?? 0,
            duration: durationMs / 1000.0,
            artworkURL: parts.count > 5 ? parts[5] : nil
        )
    }

    private static func parseTriplePipe(_ raw: String) -> FetchResult {
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 5, !parts[0].isEmpty else { return .empty }
        return FetchResult(
            track: parts[0],
            artist: parts[1],
            playing: parts[2] == "playing",
            position: Double(parts[3]) ?? 0,
            duration: Double(parts[4]) ?? 0,
            artworkURL: parts.count > 5 ? parts[5] : nil
        )
    }

    private static func runOsa(_ script: String) -> String {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Artwork

    private static func fetchArtwork(for source: MusicSource, artworkURL: String?) -> NSImage? {
        switch source {
        case .appleMusic:
            // Apple Music: export `raw data of artwork 1` to a tmp file, then load it.
            let script = """
            try
                if application "Music" is running then
                    tell application "Music"
                        set artData to raw data of artwork 1 of current track
                        set f to open for access POSIX file "\(artPath)" with write permission
                        set eof of f to 0
                        write artData to f
                        close access f
                    end tell
                end if
            end try
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            return NSImage(contentsOfFile: artPath)
        case .spotify:
            // Spotify: artwork is hosted on i.scdn.co — fetch over HTTP.
            guard let urlStr = artworkURL,
                  !urlStr.isEmpty,
                  let url = URL(string: urlStr),
                  let data = try? Data(contentsOf: url) else { return nil }
            return NSImage(data: data)
        }
    }
}

struct NowPlayingView: View {
    @ObservedObject var monitor: NowPlayingMonitor
    var isBig: Bool = false
    var accentColor: Color = DN.textPrimary
    @State private var isHovering = false

    private var artSize: CGFloat { isBig ? 52 : 30 }
    private var titleSize: CGFloat { isBig ? 12 : 10 }
    private var artistSize: CGFloat { isBig ? 9 : 8 }
    private var controlSize: CGFloat { isBig ? 12 : 9 }

    var body: some View {
        if let track = monitor.track {
            VStack(spacing: DN.spaceXS) {
                if isBig {
                    bigLayout(track: track)
                } else {
                    miniLayout(track: track)
                }

                // Progress bar + times
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06)).frame(height: isBig ? 3 : 2)
                            Capsule().fill(accentColor.opacity(0.6)).frame(width: max(geo.size.width * monitor.progress, 2), height: isBig ? 3 : 2)
                        }
                    }
                    .frame(height: isBig ? 3 : 2)

                    HStack {
                        Text(monitor.timeString(monitor.position))
                            .font(DN.mono(7))
                            .foregroundColor(DN.textDisabled)
                        Spacer()
                        Text(monitor.timeString(monitor.duration))
                            .font(DN.mono(7))
                            .foregroundColor(DN.textDisabled)
                    }
                }

                // Big: controls row, always reserved, opacity toggle
                if isBig {
                    HStack(spacing: DN.spaceLG) {
                        mediaButton("backward.fill") { monitor.runCommand("previous track") }
                        mediaButton(monitor.isPlaying ? "pause.fill" : "play.fill", size: 16) { monitor.runCommand("playpause") }
                        mediaButton("forward.fill") { monitor.runCommand("next track") }
                    }
                    .padding(.top, DN.space2xs)
                    .opacity(isHovering ? 1 : 0)
                }
            }
            .padding(.top, DN.spaceXS)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: DN.microDuration), value: isHovering)
        }
    }

    // Big: art on left, info on right, stacked
    private func bigLayout(track: String) -> some View {
        HStack(spacing: DN.spaceSM + 2) {
            albumArt(size: 56, radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(track)
                    .font(DN.body(13, weight: .semibold))
                    .foregroundColor(DN.textDisplay)
                    .lineLimit(2)

                if let artist = monitor.artist {
                    Text(artist)
                        .font(DN.mono(9))
                        .foregroundColor(DN.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // Mini: compact single row
    private func miniLayout(track: String) -> some View {
        HStack(spacing: DN.spaceSM) {
            albumArt(size: 30, radius: 5)

            VStack(alignment: .leading, spacing: 1) {
                Text(track)
                    .font(DN.body(10, weight: .medium))
                    .foregroundColor(DN.textPrimary)
                    .lineLimit(1)

                if let artist = monitor.artist {
                    Text(artist)
                        .font(DN.mono(8))
                        .foregroundColor(DN.textDisabled)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Inline controls on hover
            HStack(spacing: DN.spaceSM) {
                mediaButton("backward.fill") { monitor.runCommand("previous track") }
                mediaButton(monitor.isPlaying ? "pause.fill" : "play.fill", size: 11) { monitor.runCommand("playpause") }
                mediaButton("forward.fill") { monitor.runCommand("next track") }
            }
            .opacity(isHovering ? 1 : 0)
        }
    }

    private func albumArt(size: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            if let img = monitor.artworkImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(DN.surface)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.35, weight: .light))
                    .foregroundColor(DN.textDisabled)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private func mediaButton(_ icon: String, size: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size ?? controlSize, weight: .medium))
                .foregroundColor(accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Agents Page

struct AgentsPage: View {
    @ObservedObject var viewModel: NotchViewModel

    private var activeTasks: [SubagentTask] { viewModel.tasks.filter { !$0.isFromHistory } }
    private var hasContent: Bool { !activeTasks.isEmpty || !viewModel.scheduledTasks.isEmpty }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                if hasContent {
                    if !activeTasks.isEmpty {
                        ChatsGlassCard(tasks: activeTasks, viewModel: viewModel)
                    }
                    if !viewModel.scheduledTasks.isEmpty {
                        ScheduledGlassCard(viewModel: viewModel)
                    }
                } else {
                    emptyState
                }
            }
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.loadScheduledTasks() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.clock")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing here yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Your chats and scheduled tasks\nwill appear here")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 30)
    }
}

// Glass card showing one agent group (e.g. Claude Code sessions)
private struct AgentsGlassCard: View {
    let group: AgentGroup
    let showLiveState: Bool
    @Binding var collapsedGroups: Set<String>
    let onTapAgent: (DetectedAgent) -> Void

    private var isExpanded: Bool { !collapsedGroups.contains(group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card header
            Button(action: {
                guard group.agents.count > 1 else { return }
                withAnimation(DN.transition) { collapsedGroups.toggle(group.id) }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: group.type.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(group.type.brandColor)
                    Text(group.type.rawValue.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(group.type.brandColor)
                    if group.agents.count > 1 {
                        Text("\(group.agents.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(group.type.brandColor.opacity(0.6))
                    }
                    Spacer()
                    if group.runningCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(DN.warning).frame(width: 5, height: 5)
                            Text("\(group.runningCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if group.agents.count > 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, isExpanded ? 8 : 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.agents) { agent in
                        AgentSessionRow(agent: agent, showLiveState: showLiveState, isCompact: false) {
                            onTapAgent(agent)
                        }
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 18)
        .animation(DN.transition, value: isExpanded)
    }
}

// Glass card showing active chat tasks
private struct ChatsGlassCard: View {
    let tasks: [SubagentTask]
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("CHATS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(tasks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    AgentRow(
                        task: task,
                        isCompact: viewModel.settings.compactAgentRows,
                        activityText: viewModel.activityText(for: task)
                    ) {
                        withAnimation(DN.transition) {
                            viewModel.viewState = .agentChat(task.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 18)
    }
}

// Glass card showing scheduled tasks
private struct ScheduledGlassCard: View {
    @ObservedObject var viewModel: NotchViewModel

    private var isExpanded: Bool { !viewModel.settings.collapsedGroups.contains("scheduled") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: {
                withAnimation(DN.transition) {
                    viewModel.settings.collapsedGroups.toggle("scheduled")
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DN.warning)
                    Text("SCHEDULED")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let enabled = viewModel.scheduledTasks.filter { $0.enabled }.count
                    if enabled > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(DN.warning).frame(width: 5, height: 5)
                            Text("\(enabled)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
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
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(viewModel.scheduledTasks) { task in
                        ScheduledTaskRow(task: task, viewModel: viewModel)
                    }
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCell(cornerRadius: 18)
        .animation(DN.transition, value: isExpanded)
    }
}

// MARK: - Scheduled Tasks Section

struct ScheduledTasksSection: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var editor: ScheduledTaskEditorContext?

    private var isExpanded: Bool { !viewModel.settings.collapsedGroups.contains("scheduled") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: {
                withAnimation(DN.transition) {
                    viewModel.settings.collapsedGroups.toggle("scheduled")
                }
            }) {
                HStack(spacing: DN.spaceSM) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DN.warning)
                        .frame(width: 14)

                    Text("Scheduled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DN.textSecondary)

                    Text("\(viewModel.scheduledTasks.filter { $0.enabled }.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DN.textDisabled)

                    Spacer()

                    Button {
                        editor = ScheduledTaskEditorContext(task: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DN.textDisabled)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, DN.spaceMD)
                .padding(.vertical, DN.spaceSM)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(viewModel.scheduledTasks) { task in
                        ScheduledTaskRow(task: task, viewModel: viewModel)
                    }
                }
            }
        }
        .contentCard(cornerRadius: DN.radiusMD)
        .sheet(item: $editor) { context in
            ScheduledTaskEditor(
                viewModel: viewModel,
                task: context.task,
                onDismiss: { editor = nil }
            )
        }
    }
}

struct ScheduledTaskRow: View {
    let task: ScheduledTask
    @ObservedObject var viewModel: NotchViewModel
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var showEditor = false

    private var statusLabel: String? {
        switch task.lastStatus {
        case "completed": return "✓"
        case .some: return "✗"
        case .none: return nil
        }
    }

    private var statusColor: Color {
        switch task.lastStatus {
        case "completed": return DN.success
        default: return DN.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: DN.spaceSM) {
                Circle()
                    .fill(task.enabled ? DN.warning : DN.textDisabled)
                    .frame(width: 5, height: 5)

                VStack(alignment: .leading, spacing: 1) {
                    Text(task.name)
                        .font(DN.body(10, weight: .medium))
                        .foregroundColor(task.enabled ? DN.textPrimary : DN.textDisabled)
                        .lineLimit(1)

                    HStack(spacing: DN.spaceXS) {
                        if task.notifyUser {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 7))
                                .foregroundColor(DN.accent.opacity(0.7))
                        }

                        Text(task.scheduleHuman)
                            .font(DN.mono(8))
                            .foregroundColor(DN.textDisabled)

                        if let statusLabel {
                            Text("·")
                                .foregroundColor(DN.textDisabled)
                            Text(statusLabel)
                                .font(DN.mono(8))
                                .foregroundColor(statusColor)
                        }

                        if task.runCount > 0 {
                            Text("·")
                                .foregroundColor(DN.textDisabled)
                            Text("\(task.runCount)×")
                                .font(DN.mono(8))
                                .foregroundColor(DN.textDisabled)
                        }
                    }
                }

                Spacer()

                if isHovering {
                    Button(action: { viewModel.runScheduledTaskNow(task.id) }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundColor(DN.success)
                    }
                    .buttonStyle(.plain)

                    Button(action: { showEditor = true }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundColor(DN.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        viewModel.toggleScheduledTask(task.id, enabled: !task.enabled)
                    }) {
                        Image(systemName: task.enabled ? "pause.circle" : "play.circle")
                            .font(.system(size: 12))
                            .foregroundColor(task.enabled ? DN.warning : DN.success)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(DN.transition) {
                            viewModel.deleteScheduledTask(task.id)
                        }
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(DN.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DN.spaceSM)
            .padding(.vertical, DN.spaceXS + 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if task.lastResultSummary != nil {
                    withAnimation(DN.transition) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded: show last result
            if isExpanded, let summary = task.lastResultSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)

                    Text("LAST OUTPUT")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(DN.textDisabled)

                    MarkdownView(text: summary, isFinal: true)
                        .lineLimit(10)
                }
                .padding(.horizontal, DN.spaceMD)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            Rectangle()
                .fill(Color.white.opacity(isHovering || isExpanded ? 0.05 : 0.0))
        )
        .animation(DN.transition, value: isHovering)
        .onHover { isHovering = $0 }
        .sheet(isPresented: $showEditor) {
            ScheduledTaskEditor(
                viewModel: viewModel,
                task: task,
                onDismiss: { showEditor = false }
            )
        }
    }
}

private struct ScheduledTaskEditorContext: Identifiable {
    let id = UUID()
    let task: ScheduledTask?
}

private struct ScheduledTaskEditor: View {
    @ObservedObject var viewModel: NotchViewModel
    let task: ScheduledTask?
    let onDismiss: () -> Void

    @State private var draft: ScheduledTaskDraft

    init(
        viewModel: NotchViewModel,
        task: ScheduledTask?,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.task = task
        self.onDismiss = onDismiss
        _draft = State(initialValue: ScheduledTaskDraft(
            name: task?.name ?? "",
            prompt: task?.prompt ?? "",
            cron: task?.cron ?? "0 9 * * *",
            notifyUser: task?.notifyUser ?? true,
            provider: task?.provider ?? viewModel.activeProviderType,
            modelId: task?.modelId ?? viewModel.settings.selectedDefaultModel
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(task == nil ? "New scheduled task" : "Edit scheduled task")
                .font(.system(size: 18, weight: .semibold))
            TextField("Name", text: $draft.name)
            TextField("Prompt", text: $draft.prompt, axis: .vertical)
                .lineLimit(3...7)
            TextField("Cron schedule", text: $draft.cron)
            Picker("Provider", selection: $draft.provider) {
                ForEach(["anthropic", "openai", "openrouter", "deepseek", "custom"], id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }
            TextField("Model", text: $draft.modelId)
            Toggle("Notify with macOS", isOn: $draft.notifyUser)
            if let error = viewModel.scheduledTaskError {
                Text(error).font(.caption).foregroundStyle(DN.accent)
            }
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Save") {
                    if let task {
                        viewModel.updateScheduledTask(task.id, draft: draft)
                    } else {
                        viewModel.createScheduledTask(draft)
                    }
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - Mini Calendar

struct MiniCalendarView: View {
    let compact: Bool

    private let daysOfWeek = ["S", "M", "T", "W", "T", "F", "S"]
    private var cal: Calendar { Calendar.current }
    private var today: Date { Date() }
    private var currentDay: Int { cal.component(.day, from: today) }

    private var monthName: String {
        let f = DateFormatter()
        f.dateFormat = compact ? "MMM" : "MMMM"
        return f.string(from: today).uppercased()
    }

    private var yearString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy"
        return f.string(from: today)
    }

    private var daysInMonth: Int {
        cal.range(of: .day, in: .month, for: today)?.count ?? 30
    }

    private var firstWeekday: Int {
        let comps = cal.dateComponents([.year, .month], from: today)
        guard let first = cal.date(from: comps) else { return 0 }
        return (cal.component(.weekday, from: first) - 1) % 7
    }

    var body: some View {
        if compact {
            compactCalendar
        } else {
            fullCalendar
        }
    }

    private var compactCalendar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(monthName.capitalized)
                .font(DN.body(10, weight: .medium))
                .foregroundColor(DN.textDisabled)

            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(1...daysInMonth, id: \.self) { day in
                            VStack(spacing: 2) {
                                Text(dayOfWeekLabel(day))
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundColor(day == currentDay ? DN.textPrimary : DN.textDisabled.opacity(0.6))
                                Text("\(day)")
                                    .font(.system(size: 10, weight: day == currentDay ? .semibold : .regular, design: .rounded))
                                    .foregroundColor(dayColor(day))
                                    .monospacedDigit()
                            }
                            .frame(width: 20, height: 26)
                            .background {
                                if day == currentDay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                }
                            }
                            .id(day)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(max(currentDay - 2, 1), anchor: .leading)
                    }
                }
            }
        }
    }

    private var fullCalendar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(monthName)
                    .font(DN.label(8))
                    .tracking(1.5)
                    .foregroundColor(DN.textSecondary)
                Spacer()
                Text(yearString)
                    .font(DN.mono(8))
                    .foregroundColor(DN.textDisabled)
            }
            .padding(.bottom, 6)

            HStack(spacing: 0) {
                ForEach(daysOfWeek, id: \.self) { day in
                    Text(day)
                        .font(DN.label(6))
                        .tracking(0.5)
                        .foregroundColor(DN.textDisabled)
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                }
            }

            Rectangle()
                .fill(DN.border)
                .frame(height: 1)
                .padding(.vertical, 3)

            let rows = buildCalendarDays()
            VStack(spacing: 2) {
                ForEach(0..<rows.count, id: \.self) { rowIdx in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let day = rows[rowIdx][col]
                            if day > 0 {
                                Text("\(day)")
                                    .font(DN.mono(8, weight: day == currentDay ? .bold : .regular))
                                    .foregroundColor(dayColor(day))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 16)
                                    .background {
                                        if day == currentDay {
                                            Circle()
                                                .fill(DN.textDisplay)
                                                .frame(width: 15, height: 15)
                                        }
                                    }
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 16)
                            }
                        }
                    }
                }
            }
        }
        .padding(DN.spaceSM)
        .contentCard(cornerRadius: DN.radiusMD)
    }

    private func dayColor(_ day: Int) -> Color {
        if day == currentDay { return DN.textDisplay }
        if day < currentDay { return DN.textDisabled }
        return DN.textPrimary
    }

    private func dayOfWeekLabel(_ day: Int) -> String {
        let comps = cal.dateComponents([.year, .month], from: today)
        var dc = comps
        dc.day = day
        guard let date = cal.date(from: dc) else { return "" }
        let weekday = cal.component(.weekday, from: date)
        return ["S","M","T","W","T","F","S"][weekday - 1]
    }

    private func buildCalendarDays() -> [[Int]] {
        var rows: [[Int]] = []
        var row: [Int] = Array(repeating: 0, count: firstWeekday)
        for day in 1...daysInMonth {
            row.append(day)
            if row.count == 7 {
                rows.append(row)
                row = []
            }
        }
        if !row.isEmpty {
            while row.count < 7 { row.append(0) }
            rows.append(row)
        }
        return rows
    }
}

// MARK: - Pinned Widget Views

struct PinnedRAMView: View {
    @ObservedObject var monitor: SystemStatsMonitor
    private var pct: Double { monitor.ramTotal > 0 ? monitor.ramUsed / monitor.ramTotal : 0 }
    private var color: Color {
        if pct > 0.85 { return DN.accent }
        if pct > 0.6 { return DN.warning }
        return DN.success
    }
    var body: some View {
        HStack(spacing: DN.spaceSM) {
            ZStack {
                ForEach(0..<20, id: \.self) { i in
                    let angle = Angle.degrees(135 + Double(i) * (270.0 / 20.0))
                    let filled = Double(i) / 20.0 < pct
                    Capsule()
                        .fill(filled ? color : Color.white.opacity(0.06))
                        .frame(width: 1.5, height: 4)
                        .offset(y: -16)
                        .rotationEffect(angle)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("RAM")
                    .font(DN.label(7))
                    .tracking(1.2)
                    .foregroundColor(DN.textDisabled)
                Text("\(Int(pct * 100))%")
                    .font(DN.mono(14, weight: .light))
                    .foregroundColor(DN.textDisplay)
                Text(String(format: "%.1f / %.0f GB", monitor.ramUsed / (1024 * 1024 * 1024), monitor.ramTotal / (1024 * 1024 * 1024)))
                    .font(DN.mono(7))
                    .foregroundColor(DN.textDisabled)
            }
        }
    }
}

struct PinnedDiskView: View {
    @ObservedObject var monitor: SystemStatsMonitor
    private var pct: Double { monitor.diskTotal > 0 ? monitor.diskUsed / monitor.diskTotal : 0 }
    private var color: Color {
        if pct > 0.9 { return DN.accent }
        if pct > 0.75 { return DN.warning }
        return DN.textSecondary
    }
    var body: some View {
        HStack(spacing: DN.spaceSM) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.06), lineWidth: 3).frame(width: 36, height: 36)
                Circle().trim(from: 0, to: pct)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("DISK")
                    .font(DN.label(7))
                    .tracking(1.2)
                    .foregroundColor(DN.textDisabled)
                Text("\(Int(pct * 100))%")
                    .font(DN.mono(14, weight: .light))
                    .foregroundColor(DN.textDisplay)
                Text(String(format: "%.0f / %.0f GB", monitor.diskUsed / (1024 * 1024 * 1024), monitor.diskTotal / (1024 * 1024 * 1024)))
                    .font(DN.mono(7))
                    .foregroundColor(DN.textDisabled)
            }
        }
    }
}

struct PinnedNetworkView: View {
    @ObservedObject var monitor: SystemStatsMonitor
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(DN.success)
                Text("DOWN")
                    .font(DN.label(6))
                    .tracking(0.8)
                    .foregroundColor(DN.textDisabled)
                Spacer()
                Text(fmtBytes(monitor.netDown))
                    .font(DN.mono(9, weight: .medium))
                    .foregroundColor(DN.success)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(DN.warning)
                Text("UP")
                    .font(DN.label(6))
                    .tracking(0.8)
                    .foregroundColor(DN.textDisabled)
                Spacer()
                Text(fmtBytes(monitor.netUp))
                    .font(DN.mono(9, weight: .medium))
                    .foregroundColor(DN.warning)
            }
        }
    }
}

struct PinnedUptimeView: View {
    @ObservedObject var monitor: SystemStatsMonitor
    var body: some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: "clock")
                .font(.system(size: 12))
                .foregroundColor(DN.textDisabled)
            VStack(alignment: .leading, spacing: 2) {
                Text("UPTIME")
                    .font(DN.label(7))
                    .tracking(1.2)
                    .foregroundColor(DN.textDisabled)
                Text(monitor.uptimeString)
                    .font(DN.mono(12, weight: .medium))
                    .foregroundColor(DN.textPrimary)
            }
        }
    }
}

struct PinnedProcessView: View {
    @ObservedObject var monitor: SystemStatsMonitor
    var body: some View {
        HStack(spacing: DN.spaceSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PROCESSES")
                    .font(DN.label(7))
                    .tracking(1.2)
                    .foregroundColor(DN.textDisabled)
                Text("\(monitor.processes.count)")
                    .font(DN.mono(16, weight: .light))
                    .foregroundColor(DN.textDisplay)
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(monitor.processes.prefix(5).enumerated()), id: \.offset) { _, proc in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(proc.cpu > 10 ? DN.warning : DN.textSecondary.opacity(0.5))
                        .frame(width: 4, height: max(4, CGFloat(proc.cpu / 2)))
                }
            }
            .frame(height: 24)
        }
    }
}
