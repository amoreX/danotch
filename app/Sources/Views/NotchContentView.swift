import SwiftUI
import EventKit

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var chatInputText: String = ""
    @FocusState private var isChatInputFocused: Bool

    private var isExpanded: Bool {
        // Always show left column (widgets) when in edit mode
        if viewModel.isWidgetEditMode { return false }
        return viewModel.viewState != .overview
    }

    var body: some View {
        ZStack {
            if !isExpanded {
                leftColumn
                    .transition(.opacity)
            }

            if isExpanded {
                mainColumn
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isExpanded)
        .animation(.easeOut(duration: 0.3), value: viewModel.viewState)
        .onChange(of: viewModel.shouldFocusChatInput) { _, shouldFocus in
            if shouldFocus {
                isChatInputFocused = true
                viewModel.shouldFocusChatInput = false
            }
        }
    }

    // MARK: - Widget Grid Constants
    // Content area: 540px expanded width − 8px horizontal padding = 532px
    private let gridCols = 3
    private let gridGap: CGFloat = 6
    private let gridRowH: CGFloat = 80
    private let gridW: CGFloat = 532
    private var gridColW: CGFloat { (gridW - CGFloat(gridCols - 1) * gridGap) / CGFloat(gridCols) }

    // MARK: - Left Column (Grid layout)

    @State private var calSelectedDay = Calendar.current.component(.day, from: Date())

    // Drag state
    @State private var draggingSlotId: String? = nil
    @State private var ghostX: CGFloat = 0
    @State private var ghostY: CGFloat = 0
    @State private var ghostW: CGFloat = 0
    @State private var ghostH: CGFloat = 0
    @State private var dragHitSlotId: String? = nil
    @State private var editHoveredId: String? = nil
    @State private var borderWidth: [String: CGFloat] = [:]

    @ViewBuilder
    private var leftColumn: some View {
        if viewModel.settings.widgetSlots.isEmpty {
            emptyWidgetState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let placements = packWidgetsIntoGrid(viewModel.settings.widgetSlots)
            let maxRow = placements.map { $0.row + $0.slot.size.rowSpan }.max() ?? 1
            let totalH = CGFloat(maxRow) * gridRowH + CGFloat(maxRow - 1) * gridGap

            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: gridW, height: totalH)

                ForEach(placements, id: \.slot.id) { placement in
                    widgetCell(placement, placements: placements)
                }

                // Ghost widget — follows cursor during drag
                if let dragId = draggingSlotId,
                   let dragged = placements.first(where: { $0.slot.id == dragId }) {
                    widgetView(for: dragged.slot, cellHeight: ghostH, expandsUpward: dragged.row > 1)
                        .frame(width: ghostW, height: ghostH)
                        .clipped()
                        .scaleEffect(1.03)
                        .opacity(0.88)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                        .offset(x: ghostX - ghostW / 2, y: ghostY - ghostH / 2)
                        .allowsHitTesting(false)
                        .zIndex(100)
                }
            }
            .coordinateSpace(name: "widgetGrid")
            .frame(width: gridW, height: totalH, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: viewModel.settings.widgetSlots.count)
            .animation(.easeOut(duration: DN.microDuration), value: viewModel.isWidgetEditMode)
        }
    }

    private func widgetCell(_ placement: GridPlacement, placements: [GridPlacement]) -> some View {
        let cs = placement.slot.size.colSpan
        let rs = placement.slot.size.rowSpan
        let w = CGFloat(cs) * gridColW + CGFloat(cs - 1) * gridGap
        let h = CGFloat(rs) * gridRowH + CGFloat(rs - 1) * gridGap
        let x = CGFloat(placement.col) * (gridColW + gridGap)
        let y = CGFloat(placement.row) * (gridRowH + gridGap)

        let isCalendar = placement.slot.type == .calendar
        let isDragging = draggingSlotId == placement.slot.id
        let isHovered = editHoveredId == placement.slot.id
        let bw = borderWidth[placement.slot.id] ?? 0

        return Group {
            if isDragging && viewModel.isWidgetEditMode {
                // Placeholder: dashed outline where dragged widget was
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            .foregroundColor(.white.opacity(0.12))
                    )
                    .frame(width: w, height: h)
            } else {
                // Normal widget — block all interactivity in edit mode
                Group {
                    if isCalendar {
                        widgetView(for: placement.slot, cellHeight: h, expandsUpward: placement.row > 1)
                            .frame(width: w, height: h)
                    } else {
                        widgetView(for: placement.slot, cellHeight: h, expandsUpward: placement.row > 1)
                            .frame(width: w, height: h)
                            .clipped()
                    }
                }
                .allowsHitTesting(!viewModel.isWidgetEditMode)
                // Animated border on hover in edit mode
                .overlay {
                    if viewModel.isWidgetEditMode {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: bw)
                            .animation(.easeOut(duration: 0.14), value: bw)
                    }
                }
                // Delete button
                .overlay(alignment: .topLeading) {
                    if viewModel.isWidgetEditMode {
                        widgetMinusButton(slot: placement.slot)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                // Drag gesture in edit mode
                .gesture(
                    viewModel.isWidgetEditMode
                        ? DragGesture(minimumDistance: 3, coordinateSpace: .named("widgetGrid"))
                            .onChanged { val in
                                if draggingSlotId == nil {
                                    draggingSlotId = placement.slot.id
                                    ghostW = w
                                    ghostH = h
                                    NSCursor.closedHand.push()
                                }
                                ghostX = val.location.x
                                ghostY = val.location.y
                                // Find which slot the ghost center is over
                                for p in placements where p.slot.id != placement.slot.id {
                                    let px = CGFloat(p.col) * (gridColW + gridGap)
                                    let py = CGFloat(p.row) * (gridRowH + gridGap)
                                    let pw = CGFloat(p.slot.size.colSpan) * gridColW + CGFloat(p.slot.size.colSpan - 1) * gridGap
                                    let ph = CGFloat(p.slot.size.rowSpan) * gridRowH + CGFloat(p.slot.size.rowSpan - 1) * gridGap
                                    if val.location.x >= px && val.location.x <= px + pw &&
                                       val.location.y >= py && val.location.y <= py + ph {
                                        dragHitSlotId = p.slot.id
                                        break
                                    }
                                }
                            }
                            .onEnded { _ in
                                if let targetId = dragHitSlotId {
                                    var slots = viewModel.settings.widgetSlots
                                    if let fromIdx = slots.firstIndex(where: { $0.id == placement.slot.id }),
                                       let toIdx = slots.firstIndex(where: { $0.id == targetId }) {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            slots.swapAt(fromIdx, toIdx)
                                            viewModel.settings.widgetSlots = slots
                                        }
                                    }
                                }
                                draggingSlotId = nil
                                dragHitSlotId = nil
                                NSCursor.pop()
                            }
                        : nil
                )
                // Grab cursor + border on hover in edit mode
                .onHover { hovering in
                    if viewModel.isWidgetEditMode {
                        editHoveredId = hovering ? placement.slot.id : nil
                        withAnimation(.easeOut(duration: 0.14)) {
                            borderWidth[placement.slot.id] = hovering ? 1.5 : 0
                        }
                        if hovering && draggingSlotId == nil {
                            NSCursor.openHand.push()
                        } else if !hovering {
                            NSCursor.pop()
                        }
                    }
                }
            }
        }
        .zIndex(isDragging ? 0 : (isCalendar ? 5 : 0))
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isDragging)
        .offset(x: x, y: y)
    }

    private var emptyWidgetState: some View {
        VStack(spacing: DN.spaceXS) {
            Spacer()
            Image(systemName: "square.dashed")
                .font(.system(size: 24))
                .foregroundColor(DN.textDisabled.opacity(0.4))
            Text("No widgets")
                .font(DN.label(9))
                .tracking(0.8)
                .foregroundColor(DN.textDisabled)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func widgetView(for slot: WidgetSlot, cellHeight: CGFloat = 80, expandsUpward: Bool = true) -> some View {
        switch slot.type {
        case .music:
            MusicCard(monitor: viewModel.nowPlaying)

        case .calendar:
            DateStripCard(
                events: viewModel.calendarEvents,
                selectedDay: $calSelectedDay,
                height: cellHeight,
                expandsUpward: expandsUpward
            ) { day in
                calSelectedDay = day
            }

        case .clock:
            ClockWidget(viewModel: viewModel, size: slot.size)

        case .cpu:
            CPUCardWidget(statsMonitor: viewModel.statsMonitor)

        case .battery:
            BatteryCardWidget(monitor: viewModel.batteryMonitor)

        case .agentCount:
            AgentCountCardWidget(agentMonitor: viewModel.agentMonitor)

        case .ram:
            RAMCardWidget(statsMonitor: viewModel.statsMonitor)

        case .disk:
            DiskCardWidget(statsMonitor: viewModel.statsMonitor)

        case .network:
            NetworkCardWidget(statsMonitor: viewModel.statsMonitor)

        case .uptime:
            UptimeCardWidget(statsMonitor: viewModel.statsMonitor)

        case .processes:
            ProcessesCardWidget(statsMonitor: viewModel.statsMonitor)
        }
    }

    private func widgetMinusButton(slot: WidgetSlot) -> some View {
        Button(action: {
            withAnimation(.easeOut(duration: DN.microDuration)) {
                viewModel.settings.widgetSlots.removeAll { $0.id == slot.id }
            }
        }) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.82, green: 0.1, blue: 0.1))
                    .frame(width: 18, height: 18)
                Image(systemName: "minus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(.plain)
        .padding(5)
    }

    // MARK: - Divider

    private var dividerBar: some View {
        Rectangle()
            .fill(DN.border)
            .frame(width: 1)
            .padding(.vertical, DN.spaceXS)
            .padding(.horizontal, DN.spaceSM + DN.space2xs)
    }

    // MARK: - Main Column

    @ViewBuilder
    private var mainColumn: some View {
        switch viewModel.viewState {
        case .overview:
            overviewRightColumn
        case .taskList:
            agentsColumn
        case .agentChat(let taskId):
            AgentChatView(viewModel: viewModel, taskId: taskId)
        case .stats, .processList, .settings, .notifications:
            EmptyView()
        }
    }

    // MARK: - Overview right column

    private var overviewRightColumn: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            if viewModel.agentMonitor.agents.isEmpty && activeTasks.isEmpty && viewModel.scheduledTasks.isEmpty {
                emptyAgentState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DN.spaceSM) {
                        ForEach(viewModel.agentMonitor.groupedAgents) { group in
                            AgentGroupView(group: group, isCompact: viewModel.settings.compactAgentRows, collapsedGroups: $viewModel.settings.collapsedGroups, showLiveState: viewModel.settings.showAgentLiveState) { agent in
                                viewModel.agentMonitor.activateAgent(agent)
                            }
                        }

                        if !viewModel.scheduledTasks.isEmpty {
                            ScheduledTasksSection(viewModel: viewModel)
                        }

                        if !activeTasks.isEmpty {
                            tasksSection(compact: viewModel.settings.compactAgentRows)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            viewModel.loadScheduledTasks()
        }
    }

    // MARK: - Empty state

    private var emptyAgentState: some View {
        VStack(spacing: DN.spaceSM) {
            Spacer().frame(height: DN.spaceSM)
            Text("NO AGENTS DETECTED")
                .font(DN.label(9))
                .tracking(0.8)
                .foregroundColor(DN.textDisabled)

            Text("Start Claude Code, Cursor, or Codex\nto see them here")
                .font(DN.body(10))
                .foregroundColor(DN.textDisabled.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Full agents column (conversations only)

    private var agentsColumn: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            HStack(spacing: DN.spaceSM) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DN.textSecondary)

                Text("CONVERSATIONS")
                    .font(DN.label(9))
                    .tracking(0.8)
                    .foregroundColor(DN.textSecondary)

                Spacer()

                HStack(spacing: DN.spaceXS) {
                    IconActionButton(icon: "plus", label: "NEW") {
                        withAnimation(DN.transition) {
                            viewModel.viewState = .overview
                            viewModel.shouldFocusChatInput = true
                        }
                    }
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: DN.spaceXS) {
                    // Active / recent in-memory tasks
                    ForEach(viewModel.tasks.filter { !$0.isFromHistory }) { task in
                        AgentRow(
                            task: task,
                            isCompact: false,
                            activityText: viewModel.activityText(for: task)
                        ) {
                            withAnimation(DN.transition) {
                                viewModel.viewState = .agentChat(task.id)
                            }
                        }
                    }

                    // Past threads from DB
                    if !viewModel.threadHistory.isEmpty {
                        let loadedThreadIds = Set(viewModel.tasks.compactMap { $0.threadId })

                        let unloaded = viewModel.threadHistory.filter { !loadedThreadIds.contains($0.id) }
                        if !unloaded.isEmpty {
                            Divider()
                                .background(DN.border)
                                .padding(.vertical, DN.spaceXS)

                            Text("HISTORY")
                                .font(DN.label(8))
                                .tracking(1.2)
                                .foregroundColor(DN.textDisabled)
                                .padding(.leading, 4)

                            ForEach(unloaded) { thread in
                                threadRow(thread)
                            }
                        }
                    }

                    if activeTasks.isEmpty && viewModel.threadHistory.isEmpty {
                        VStack(spacing: DN.spaceSM) {
                            Spacer().frame(height: DN.spaceLG)
                            Text("NO CONVERSATIONS")
                                .font(DN.label(9))
                                .tracking(0.8)
                                .foregroundColor(DN.textDisabled)
                            Text("Start a chat from the HOME tab")
                                .font(DN.body(10))
                                .foregroundColor(DN.textDisabled.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            viewModel.loadThreadHistory()
            viewModel.loadScheduledTasks()
        }
    }

    // MARK: - Thread History Row

    private func threadRow(_ thread: NotchViewModel.ThreadSummary) -> some View {
        Button(action: {
            viewModel.loadThread(thread.id)
        }) {
            HStack(spacing: DN.spaceSM) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DN.textDisabled)

                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title ?? "Conversation")
                        .font(DN.body(11))
                        .foregroundColor(DN.textPrimary)
                        .lineLimit(1)

                    Text(formatThreadDate(thread.updatedAt))
                        .font(DN.mono(8))
                        .foregroundColor(DN.textDisabled)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(DN.textDisabled)
            }
            .padding(.horizontal, DN.spaceSM)
            .padding(.vertical, DN.spaceXS + 2)
            .background(DN.surface.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(DN.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatThreadDate(_ iso: String) -> String {
        formatRelativeDate(iso, fallbackFormat: "MMM d")
    }

    // MARK: - Chat Input Bar

    private var chatInputBar: some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isChatInputFocused ? DN.accent.opacity(0.8) : DN.textDisabled)

            TextField("", text: $chatInputText, prompt: Text("Ask anything...")
                .font(DN.body(11))
                .foregroundColor(DN.textDisabled)
            )
            .textFieldStyle(.plain)
            .font(DN.body(11))
            .foregroundColor(DN.textPrimary)
            .focused($isChatInputFocused)
            .onHover { hovering in
                if hovering { NSCursor.iBeam.push() } else { NSCursor.pop() }
            }
            .onChange(of: isChatInputFocused) { _, focused in
                viewModel.isChatInputActive = focused
            }
            .onSubmit { submitChat() }

            if !chatInputText.isEmpty {
                Button(action: { submitChat() }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DN.black)
                        .frame(width: 18, height: 18)
                        .background(DN.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, DN.spaceSM + DN.spaceXS)
        .padding(.vertical, DN.spaceXS + 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DN.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isChatInputFocused ? DN.accent.opacity(0.4) : DN.border,
                    lineWidth: 1
                )
        )
        .animation(.easeOut(duration: DN.microDuration), value: chatInputText.isEmpty)
        .animation(.easeOut(duration: DN.microDuration), value: isChatInputFocused)
    }

    private func submitChat() {
        let text = chatInputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        chatInputText = ""
        isChatInputFocused = false
        viewModel.sendChat(message: text)
    }

    // MARK: - Tasks Section

    private var activeTasks: [SubagentTask] {
        viewModel.tasks.filter { !$0.isFromHistory }
    }

    private var isTasksExpanded: Bool { !viewModel.settings.collapsedGroups.contains("tasks") }

    private func tasksSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeOut(duration: DN.microDuration)) {
                    if isTasksExpanded {
                        viewModel.settings.collapsedGroups.insert("tasks")
                    } else {
                        viewModel.settings.collapsedGroups.remove("tasks")
                    }
                }
            }) {
                HStack(spacing: DN.spaceSM) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DN.textSecondary)
                        .frame(width: 14)

                    Text("TASKS")
                        .font(DN.label(9))
                        .tracking(1.0)
                        .foregroundColor(DN.textSecondary)

                    Text("\(activeTasks.count)")
                        .font(DN.mono(9, weight: .medium))
                        .foregroundColor(DN.textDisabled)

                    Spacer()

                    let active = activeTasks.filter { $0.isActive }.count
                    if active > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(DN.warning).frame(width: 4, height: 4)
                            Text("\(active) ACTIVE")
                                .font(DN.label(7))
                                .tracking(0.6)
                                .foregroundColor(DN.warning)
                        }
                    }

                    Image(systemName: isTasksExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(DN.textDisabled)
                }
                .padding(.horizontal, DN.spaceSM)
                .padding(.vertical, DN.spaceXS + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isTasksExpanded {
                VStack(spacing: 1) {
                    ForEach(activeTasks) { task in
                        AgentRow(
                            task: task,
                            isCompact: compact,
                            activityText: viewModel.activityText(for: task)
                        ) {
                            withAnimation(DN.transition) {
                                viewModel.viewState = .agentChat(task.id)
                            }
                        }
                    }
                }
            }
        }
        .background(DN.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DN.border, lineWidth: 1)
        )
    }

}

// MARK: - Icon Action Button (icon only, label on hover)

struct IconActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))

                if isHovering {
                    Text(label)
                        .font(DN.label(7))
                        .tracking(0.6)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .foregroundColor(isHovering ? DN.textPrimary : DN.textDisabled)
            .padding(.horizontal, isHovering ? DN.spaceSM : DN.spaceSM)
            .padding(.vertical, DN.spaceXS + 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isHovering ? DN.borderVisible : DN.border, lineWidth: 1)
            )
            .animation(.easeOut(duration: DN.microDuration), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
                withAnimation(.easeOut(duration: DN.microDuration)) {
                    if collapsedGroups.contains(group.id) {
                        collapsedGroups.remove(group.id)
                    } else {
                        collapsedGroups.insert(group.id)
                    }
                }
            }) {
                HStack(spacing: DN.spaceSM) {
                    Image(systemName: group.type.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(group.type.brandColor)
                        .frame(width: 14)

                    Text(group.type.rawValue.uppercased())
                        .font(DN.label(9))
                        .tracking(1.0)
                        .foregroundColor(group.type.brandColor)

                    if group.agents.count > 1 {
                        Text("\(group.agents.count)")
                            .font(DN.mono(9, weight: .medium))
                            .foregroundColor(group.type.brandColor.opacity(0.6))
                    }

                    Spacer()

                    if group.runningCount > 0 {
                        HStack(spacing: 3) {
                            Circle().fill(DN.warning).frame(width: 4, height: 4)
                            Text("\(group.runningCount) ACTIVE")
                                .font(DN.label(7))
                                .tracking(0.6)
                                .foregroundColor(DN.warning)
                        }
                    }

                    if canCollapse {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(DN.textDisabled)
                            .rotationEffect(.degrees(isGroupExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, DN.spaceSM)
                .padding(.vertical, DN.spaceXS + 1)
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
        .background(DN.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DN.border, lineWidth: 1)
        )
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
                    // Project name or display name
                    Text(agent.displayName)
                        .font(DN.body(11, weight: .medium))
                        .foregroundColor(DN.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Elapsed
                    Text(agent.elapsed)
                        .font(DN.mono(9))
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
                        HStack(spacing: 2) {
                            Text("CPU")
                                .font(DN.label(7))
                                .tracking(0.4)
                                .foregroundColor(DN.textDisabled)
                            Text(String(format: "%.1f%%", agent.cpu))
                                .font(DN.mono(9))
                                .foregroundColor(agent.cpu > 1.0 ? DN.warning : DN.textSecondary)
                        }

                        HStack(spacing: 2) {
                            Text("MEM")
                                .font(DN.label(7))
                                .tracking(0.4)
                                .foregroundColor(DN.textDisabled)
                            Text(String(format: "%.0fMB", agent.memMB))
                                .font(DN.mono(9))
                                .foregroundColor(DN.textSecondary)
                        }

                        Spacer()
                    }
                    .padding(.top, 1)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, DN.spaceSM)
            .padding(.vertical, DN.spaceXS + 2)
            .contentShape(Rectangle())
            .background(isHovering ? DN.surface : .clear)
            .animation(.easeOut(duration: DN.microDuration), value: isHovering)
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
            .background(isHovering ? DN.surface : (isCompact ? .clear : DN.surface.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(!isCompact ? DN.border : .clear, lineWidth: 1)
            )
            .animation(.easeOut(duration: DN.microDuration), value: isHovering)
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

class NowPlayingMonitor: ObservableObject {
    @Published var track: String?
    @Published var artist: String?
    @Published var isPlaying = false
    @Published var artworkImage: NSImage?
    @Published var position: Double = 0
    @Published var duration: Double = 0

    /// Set by ViewModel whenever settings.musicSource changes
    var source: MusicSource = .auto

    private var timer: Timer?
    private var positionTimer: Timer?
    private var positionBase: Double = 0
    private var positionTimestamp: Date = Date()
    private var lastArtworkURL: String?

    var progress: Double { duration > 0 ? position / duration : 0 }

    func timeString(_ seconds: Double) -> String {
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: MediaRemote (Apple Music / system-level)
    private typealias MRGetNowPlayingFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRSendCommandFn   = @convention(c) (UInt32, AnyObject?) -> Bool
    private typealias MRRegisterFn      = @convention(c) (DispatchQueue) -> Void
    private var mrGetInfo: MRGetNowPlayingFn?
    private var mrSendCmd: MRSendCommandFn?

    private let kMRToggle:    UInt32 = 2
    private let kMRNextTrack: UInt32 = 4
    private let kMRPrevTrack: UInt32 = 5

    init() {
        loadMediaRemote()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying, self.duration > 0 else { return }
            let elapsed = Date().timeIntervalSince(self.positionTimestamp)
            self.position = min(self.positionBase + elapsed, self.duration)
        }
    }

    deinit { timer?.invalidate(); positionTimer?.invalidate() }

    private func loadMediaRemote() {
        guard let bundle = CFBundleCreate(kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")) else {
            return
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            unsafeBitCast(ptr, to: MRRegisterFn.self)(DispatchQueue.main)
        } else {
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            mrGetInfo = unsafeBitCast(ptr, to: MRGetNowPlayingFn.self)
        } else {
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            mrSendCmd = unsafeBitCast(ptr, to: MRSendCommandFn.self)
        } else {
        }
    }

    func poll() {
        switch source {
        case .spotify:
            pollSpotify { _ in }
        case .appleMusic:
            pollAppleMusic()
        case .auto:
            pollSpotify { [weak self] found in
                if !found { self?.pollAppleMusic() }
            }
        }
    }

    // MARK: Spotify (NSAppleScript — in-process, proper TCC attribution)

    // Serial queue required: NSAppleScript is not thread-safe
    private static let asQueue = DispatchQueue(label: "com.danotch.applescript")

    private func pollSpotify(completion: @escaping (Bool) -> Void) {
        Self.asQueue.async { [weak self] in
            guard let self else { return }
            let source = """
            try
                if application "Spotify" is running then
                    tell application "Spotify"
                        if player state is playing or player state is paused then
                            set trackName to name of current track
                            set artistName to artist of current track
                            set trackPos to player position
                            set trackDur to duration of current track
                            if player state is playing then
                                set playState to "playing"
                            else
                                set playState to "paused"
                            end if
                            try
                                set artURL to artwork url of current track
                            on error
                                set artURL to ""
                            end try
                            return trackName & "|||" & artistName & "|||" & playState & "|||" & trackPos & "|||" & trackDur & "|||" & artURL
                        end if
                    end tell
                end if
            end try
            return ""
            """
            let result = self.runAppleScript(source)
            guard !result.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let parts = result.components(separatedBy: "|||")
            let trim  = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
            let newTrack  = parts.count > 0 && !trim(parts[0]).isEmpty ? trim(parts[0]) : nil
            let newArtist = parts.count > 1 && !trim(parts[1]).isEmpty ? trim(parts[1]) : nil
            let playing   = parts.count > 2 && trim(parts[2]) == "playing"
            let pos       = parts.count > 3 ? Double(trim(parts[3])) ?? 0 : 0
            let durMs     = parts.count > 4 ? Double(trim(parts[4])) ?? 0 : 0   // Spotify: milliseconds
            let artURL    = parts.count > 5 ? trim(parts[5]) : ""

            DispatchQueue.main.async {
                let trackChanged = newTrack != self.track
                self.track     = newTrack
                self.artist    = newArtist
                self.isPlaying = playing
                self.duration  = durMs / 1000.0
                self.positionBase      = pos
                self.positionTimestamp = Date()
                if playing { self.position = pos }

                if trackChanged {
                    if !artURL.isEmpty { self.fetchArtwork(from: artURL) }
                    else { self.artworkImage = nil; self.lastArtworkURL = nil }
                }
                if newTrack == nil { self.artworkImage = nil; self.lastArtworkURL = nil }
                completion(newTrack != nil)
            }
        }
    }

    private func fetchArtwork(from urlStr: String) {
        guard urlStr != lastArtworkURL, let url = URL(string: urlStr) else { return }
        lastArtworkURL = urlStr
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async { self?.artworkImage = img }
        }.resume()
    }

    // MARK: Apple Music (MediaRemote)

    private func pollAppleMusic() {
        guard let mrGetInfo else { return }
        mrGetInfo(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let newTrack  = info["kMRMediaRemoteNowPlayingInfoTitle"]  as? String
            let newArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
            let newDur    = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            let newPos    = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            let playing   = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0

            let trackChanged = newTrack != self.track
            self.track     = newTrack
            self.artist    = newArtist
            self.duration  = newDur
            self.isPlaying = playing
            self.positionBase      = newPos
            self.positionTimestamp = Date()
            if playing { self.position = newPos }

            if trackChanged {
                if let artData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                   let img = NSImage(data: artData) {
                    self.artworkImage = img
                    self.lastArtworkURL = nil
                } else {
                    self.artworkImage = nil
                }
            }
            if newTrack == nil { self.artworkImage = nil }
        }
    }

    // MARK: Commands

    func runCommand(_ cmd: String) {
        // MediaRemote commands work system-wide (Spotify + Apple Music)
        let mrCmd: UInt32?
        switch cmd {
        case "playpause":      mrCmd = kMRToggle
        case "next track":     mrCmd = kMRNextTrack
        case "previous track": mrCmd = kMRPrevTrack
        default:               mrCmd = nil
        }
        if let mrCmd, let fn = mrSendCmd {
            _ = fn(mrCmd, nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.poll() }
            return
        }
        // Fallback: NSAppleScript command
        Self.asQueue.async { [weak self] in
            guard let self else { return }
            let source = """
            try
                if application "Spotify" is running then
                    tell application "Spotify" to \(cmd)
                else if application "Music" is running then
                    tell application "Music" to \(cmd)
                end if
            end try
            """
            _ = self.runAppleScript(source)
            Thread.sleep(forTimeInterval: 0.35)
            DispatchQueue.main.async { self.poll() }
        }
    }

    func seek(to progress: Double) {
        guard duration > 0 else { return }
        let pos = progress * duration
        Self.asQueue.async { [weak self] in
            guard let self else { return }
            let source = """
            try
                if application "Spotify" is running then
                    tell application "Spotify" to set player position to \(pos)
                else if application "Music" is running then
                    tell application "Music" to set player position to \(pos)
                end if
            end try
            """
            _ = self.runAppleScript(source)
            DispatchQueue.main.async { self.poll() }
        }
    }

    /// Run AppleScript on the main thread (required for TCC dialogs to appear)
    /// Called from asQueue (background), uses semaphore to wait for result without blocking main.
    private func runAppleScript(_ source: String) -> String {
        var resultStr = ""
        let sema = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let script = NSAppleScript(source: source) else { sema.signal(); return }
            var error: NSDictionary?
            let desc = script.executeAndReturnError(&error)
            if let err = error {
                let msg = err[NSAppleScript.errorMessage as String] as? String ?? "\(err)"
            }
            resultStr = desc.stringValue ?? ""
            sema.signal()
        }
        sema.wait()
        return resultStr
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
        HStack(spacing: DN.spaceSM + 4) {
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

// MARK: - Scheduled Tasks Section

struct ScheduledTasksSection: View {
    @ObservedObject var viewModel: NotchViewModel

    private var isExpanded: Bool { !viewModel.settings.collapsedGroups.contains("scheduled") }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Header
            Button(action: {
                withAnimation(.easeOut(duration: DN.microDuration)) {
                    if isExpanded {
                        viewModel.settings.collapsedGroups.insert("scheduled")
                    } else {
                        viewModel.settings.collapsedGroups.remove("scheduled")
                    }
                }
            }) {
                HStack(spacing: DN.spaceSM) {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DN.warning)

                    Text("SCHEDULED")
                        .font(DN.label(8))
                        .tracking(1.2)
                        .foregroundColor(DN.textSecondary)

                    Text("\(viewModel.scheduledTasks.filter { $0.enabled }.count)")
                        .font(DN.mono(8))
                        .foregroundColor(DN.textDisabled)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(DN.textDisabled)
                }
                .padding(.horizontal, DN.spaceSM)
                .padding(.vertical, DN.spaceXS)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(viewModel.scheduledTasks) { task in
                        ScheduledTaskRow(task: task, viewModel: viewModel)
                    }
                }
            }
        }
        .background(DN.surface.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(DN.border, lineWidth: 0.5)
        )
    }
}

struct ScheduledTaskRow: View {
    let task: ScheduledTask
    @ObservedObject var viewModel: NotchViewModel
    @State private var isHovering = false
    @State private var isExpanded = false

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

                        if let lastStatus = task.lastStatus {
                            Text("·")
                                .foregroundColor(DN.textDisabled)
                            Text(lastStatus == "completed" ? "✓" : "✗")
                                .font(DN.mono(8))
                                .foregroundColor(lastStatus == "completed" ? DN.success : DN.accent)
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
                    Button(action: {
                        viewModel.toggleScheduledTask(task.id, enabled: !task.enabled)
                    }) {
                        Image(systemName: task.enabled ? "pause.circle" : "play.circle")
                            .font(.system(size: 12))
                            .foregroundColor(task.enabled ? DN.warning : DN.success)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(.easeOut(duration: DN.microDuration)) {
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
                    withAnimation(.easeOut(duration: DN.microDuration)) {
                        isExpanded.toggle()
                    }
                }
            }

            // Expanded: show last result
            if isExpanded, let summary = task.lastResultSummary {
                VStack(alignment: .leading, spacing: DN.spaceXS) {
                    Divider().background(DN.border)

                    Text("LAST OUTPUT")
                        .font(DN.label(7))
                        .tracking(1)
                        .foregroundColor(DN.textDisabled)

                    MarkdownView(text: summary, isFinal: true)
                        .lineLimit(10)
                }
                .padding(.horizontal, DN.spaceSM)
                .padding(.bottom, DN.spaceXS + 1)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isHovering || isExpanded ? DN.surface : .clear)
        .animation(.easeOut(duration: DN.microDuration), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Calendar Cards (Date Strip + Events)

private let neutralCardBg = Color(hexStr: "111111")

// Shared card shell — neutral dark, no color gradient
private struct NeutralCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .background {
                ZStack {
                    neutralCardBg
                    GrainOverlay(opacity: 0.35)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Widget Grid System

private struct PlacedSlot {
    let slot: WidgetSlot
    let rect: CGRect
}

// Grid constants: 3 cols, 80px row height, 6px gap
// Available width = expanded(540) - hPad(4×2) = 532px
// colW = (532 - 12) / 3 ≈ 173.3px
private let wgCols    = 3
private let wgGap: CGFloat  = 6
private let wgRowH: CGFloat = 80
private let wgColW: CGFloat = (532 - wgGap * CGFloat(wgCols - 1)) / CGFloat(wgCols)

private func wgWidth(_ cs: Int) -> CGFloat { wgColW * CGFloat(cs) + wgGap * CGFloat(cs - 1) }
private func wgHeight(_ rs: Int) -> CGFloat { wgRowH * CGFloat(rs) + wgGap * CGFloat(rs - 1) }

private func computeWidgetLayout(_ slots: [WidgetSlot]) -> (placed: [PlacedSlot], addRect: CGRect) {
    var grid = Array(repeating: Array(repeating: false, count: wgCols), count: 12)
    var result: [PlacedSlot] = []

    for slot in slots {
        let cs = min(slot.size.colSpan, wgCols)
        let rs = slot.size.rowSpan
        var didPlace = false

        outer: for row in 0..<12 {
            for col in 0...(wgCols - cs) {
                var fits = true
                checkLoop: for dr in 0..<rs {
                    for dc in 0..<cs {
                        if grid[row + dr][col + dc] { fits = false; break checkLoop }
                    }
                }
                if fits {
                    for dr in 0..<rs { for dc in 0..<cs { grid[row + dr][col + dc] = true } }
                    let x = CGFloat(col) * (wgColW + wgGap)
                    let y = CGFloat(row) * (wgRowH + wgGap)
                    result.append(PlacedSlot(slot: slot, rect: CGRect(x: x, y: y, width: wgWidth(cs), height: wgHeight(rs))))
                    didPlace = true
                    break outer
                }
            }
        }
        _ = didPlace  // unused warning suppression
    }

    // Next free 1×1 slot for the add button
    var addRect = CGRect(x: 0, y: CGFloat(12) * (wgRowH + wgGap), width: wgColW, height: wgRowH)
    outerAdd: for row in 0..<12 {
        for col in 0..<wgCols where !grid[row][col] {
            addRect = CGRect(x: CGFloat(col) * (wgColW + wgGap),
                             y: CGFloat(row) * (wgRowH + wgGap),
                             width: wgColW, height: wgRowH)
            break outerAdd
        }
    }

    return (result, addRect)
}

struct WidgetGridView: View {
    let slots: [WidgetSlot]
    let isEditMode: Bool
    let viewModel: NotchViewModel
    @Binding var showPicker: Bool
    let onDelete: (String) -> Void
    let onReorder: (String, String) -> Void

    @State private var wiggle = false

    var body: some View {
        let (placed, addRect) = computeWidgetLayout(slots)
        let maxY = placed.map { $0.rect.maxY }.max() ?? 0
        let gridH = isEditMode ? max(maxY, addRect.maxY) : maxY

        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 532, height: gridH)

            ForEach(placed, id: \.slot.id) { item in
                gridCell(item: item)
                    .frame(width: item.rect.width, height: item.rect.height)
                    .offset(x: item.rect.minX, y: item.rect.minY)
            }

            if isEditMode {
                Button { showPicker = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundColor(DN.textDisabled.opacity(0.35))
                        VStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .medium))
                            Text("ADD")
                                .font(DN.label(7))
                                .tracking(1)
                        }
                        .foregroundColor(DN.textDisabled)
                    }
                }
                .buttonStyle(.plain)
                .handCursor()
                .frame(width: addRect.width, height: addRect.height)
                .offset(x: addRect.minX, y: addRect.minY)
                .transition(.opacity)
            }
        }
        .frame(height: gridH)
        .onChange(of: isEditMode) { _, editing in
            withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
                wiggle = editing
            }
            if !editing { wiggle = false }
        }
    }

    @ViewBuilder
    private func gridCell(item: PlacedSlot) -> some View {
        ZStack(alignment: .topLeading) {
            widgetContent(item.slot)
                .rotationEffect(.degrees(isEditMode && wiggle ? 1.5 : 0))
                .animation(
                    isEditMode
                        ? .easeInOut(duration: 0.12).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.15),
                    value: wiggle
                )
                .onDrag { NSItemProvider(object: item.slot.id as NSString) }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    providers.first?.loadObject(ofClass: NSString.self) { obj, _ in
                        guard let from = obj as? String, from != item.slot.id else { return }
                        DispatchQueue.main.async { onReorder(from, item.slot.id) }
                    }
                    return true
                }

            if isEditMode {
                Button { onDelete(item.slot.id) } label: {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.9)).frame(width: 16, height: 16)
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .handCursor()
                .offset(x: -5, y: -5)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func widgetContent(_ slot: WidgetSlot) -> some View {
        switch slot.type {
        case .clock:      ClockWidget(viewModel: viewModel, size: slot.size)
        case .music:      MusicCard(monitor: viewModel.nowPlaying)
        case .calendar:   CalendarWidget(events: viewModel.calendarEvents, size: slot.size)
        case .cpu:        CPUWidget(monitor: viewModel.statsMonitor)
        case .battery:    BatteryWidget(monitor: viewModel.batteryMonitor)
        case .agentCount: AgentCountWidget(agentMonitor: viewModel.agentMonitor)
        case .ram:        RAMWidget(monitor: viewModel.statsMonitor)
        case .disk:       DiskWidget(monitor: viewModel.statsMonitor)
        case .network:    NetworkWidget(monitor: viewModel.statsMonitor)
        case .uptime:     UptimeWidget(monitor: viewModel.statsMonitor)
        case .processes:  ProcessWidget(monitor: viewModel.statsMonitor)
        }
    }
}

// MARK: - Widget: Clock

private struct ClockWidget: View {
    @ObservedObject var viewModel: NotchViewModel
    let size: WidgetSize

    private let shape = UnevenRoundedRectangle(
        topLeadingRadius: 8, bottomLeadingRadius: 10,
        bottomTrailingRadius: 10, topTrailingRadius: 8, style: .continuous
    )

    var body: some View {
        let pal = viewModel.wallpaper.palette
        ZStack(alignment: .leading) {
            ZStack {
                RadialGradient(colors: [pal.dark, pal.mid], center: .bottomLeading, startRadius: 0, endRadius: 380)
                RadialGradient(colors: [pal.accent.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 160)
                GrainOverlay(opacity: 0.5)
            }
            .animation(.easeInOut(duration: 0.8), value: viewModel.wallpaper.palette)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(viewModel.timeString)
                        .font(.custom("Cakra-Normal", size: size == .wide ? 44 : 28))
                        .foregroundColor(Color(hexStr: "e8e4f4"))
                        .tracking(-1)
                    Text(viewModel.periodString)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundColor(Color(hexStr: "e8e4f4").opacity(0.45))
                }
                if size != .small {
                    Text(viewModel.dateString.uppercased())
                        .font(.system(size: 8, weight: .medium))
                        .tracking(1.5)
                        .foregroundColor(Color(hexStr: "e8e4f4").opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Music Card

private struct MusicCard: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @State private var hoveredBtn: Int? = nil
    @State private var sliderHovered = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0
    // Holds the seeked position until monitor.progress catches up (prevents snap-back)
    @State private var pendingSeek: Double? = nil

    private var displayProgress: Double {
        if isDragging { return dragProgress }
        if let p = pendingSeek { return p }
        return monitor.progress
    }

    var body: some View {
        HStack(spacing: 4) {
            // Left card: cover art | title (top) + progress bar (bottom)
            NeutralCard {
                GeometryReader { geo in
                    let h = geo.size.height
                    HStack(spacing: 0) {
                        // Cover art — square, fills full height
                        ZStack {
                            if let img = monitor.artworkImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.03)
                                Image(systemName: "music.note")
                                    .font(.system(size: 18, weight: .ultraLight))
                                    .foregroundColor(.white.opacity(0.12))
                            }
                        }
                        .frame(width: h, height: h)
                        .clipped()

                        // Title (top) + spacer + progress bar (bottom)
                        VStack(alignment: .leading, spacing: 0) {
                            // Song title + artist at top
                            VStack(alignment: .leading, spacing: 2) {
                                Text(monitor.track ?? "Nothing Playing")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(monitor.track != nil ? 0.88 : 0.28))
                                    .lineLimit(1)
                                Text(monitor.artist ?? " ")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Spacer(minLength: 0)

                            // Progress slider — fixed 14px hit area, thickens from center on hover
                            GeometryReader { bar in
                                let w = bar.size.width
                                let active = sliderHovered || isDragging
                                let trackH: CGFloat = active ? 4 : 2
                                // Snap fill when dragging/clicking, linear drift during playback
                                let filled = CGFloat(displayProgress) * w
                                let thumbW: CGFloat = 24
                                let thumbH: CGFloat = 12
                                let thumbX = min(max(filled - thumbW / 2, 0), w - thumbW)

                                ZStack(alignment: .leading) {
                                    // Track background
                                    Capsule()
                                        .fill(Color.white.opacity(0.1))
                                        .frame(height: trackH)
                                        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: active)

                                    // Filled portion — snap on drag, linear during playback
                                    Capsule()
                                        .fill(Color.white.opacity(monitor.track != nil ? 0.75 : 0))
                                        .frame(width: max(0, filled), height: trackH)
                                        .animation(isDragging ? nil : .linear(duration: 0.5), value: filled)
                                        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: active)

                                    // Pill thumb — always in hierarchy at correct position,
                                    // only opacity changes (prevents animated position on appear)
                                    Capsule()
                                        .fill(.white)
                                        .frame(width: thumbW, height: thumbH)
                                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                                        .offset(x: thumbX)
                                        .animation(nil, value: thumbX) // position always snaps
                                        .opacity(active && monitor.track != nil ? 1 : 0)
                                        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: active)
                                }
                                .frame(maxHeight: .infinity, alignment: .center)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { v in
                                            if !isDragging { isDragging = true }
                                            dragProgress = Double(max(0, min(1, v.location.x / w)))
                                        }
                                        .onEnded { v in
                                            let p = Double(max(0, min(1, v.location.x / w)))
                                            pendingSeek = p
                                            monitor.seek(to: p)
                                            isDragging = false
                                            // Clear once monitor.progress has caught up (~0.6s)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                                pendingSeek = nil
                                            }
                                        }
                                )
                            }
                            .frame(height: 14)
                            .onHover { h in
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { sliderHovered = h }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }

            // Right card: playback controls (square buttons, equal outer padding)
            NeutralCard {
                VStack(spacing: 0) {
                    musicCtrl(index: 0, icon: "backward.fill") { monitor.runCommand("previous track") }
                    musicCtrl(index: 1, icon: monitor.isPlaying ? "pause.fill" : "play.fill") {
                        monitor.runCommand("playpause")
                    }
                    .animation(.easeInOut(duration: 0.15), value: monitor.isPlaying)
                    musicCtrl(index: 2, icon: "forward.fill") { monitor.runCommand("next track") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 44)
        }
    }

    private func musicCtrl(index: Int, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(hoveredBtn == index ? 0.9 : 0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hoveredBtn == index ? 0.1 : 0))
                        .padding(4)
                )
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { inside in hoveredBtn = inside ? index : nil }
    }
}

// MARK: - Widget: Calendar

private struct CalendarWidget: View {
    @ObservedObject var events: CalendarEventsMonitor
    let size: WidgetSize
    @State private var selectedDay = Calendar.current.component(.day, from: Date())

    var body: some View {
        switch size {
        case .large:
            VStack(spacing: wgGap) {
                DateStripCard(events: events, selectedDay: $selectedDay)
                NeutralCard {
                    let dayEvents = events.eventsByDay[selectedDay] ?? []
                    Group {
                        if dayEvents.isEmpty {
                            Text("No events")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.2))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(dayEvents, id: \.eventIdentifier) { event in
                                        CompactEventRow(event: event)
                                    }
                                }
                                .padding(10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .medium, .wide:
            DateStripCard(events: events, selectedDay: $selectedDay)
        case .small:
            NeutralCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Calendar.current.monthSymbols[Calendar.current.component(.month, from: Date()) - 1].prefix(3).uppercased())
                        .font(DN.label(7)).tracking(1.5).foregroundColor(DN.textDisabled)
                    Text("\(Calendar.current.component(.day, from: Date()))")
                        .font(DN.mono(28, weight: .light)).foregroundColor(DN.textDisplay)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Widget: CPU

struct CPUWidget: View {
    @ObservedObject var monitor: SystemStatsMonitor
    private var pct: Double { monitor.cpuUsage / 100.0 }
    private var color: Color {
        if monitor.cpuUsage > 80 { return DN.accent }
        if monitor.cpuUsage > 50 { return DN.warning }
        return DN.success
    }

    var body: some View {
        NeutralCard {
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
                .animation(.easeOut(duration: 0.5), value: pct)

                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU")
                        .font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)
                    Text("\(Int(monitor.cpuUsage))%")
                        .font(DN.mono(14, weight: .light)).foregroundColor(DN.textDisplay)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: Battery

struct BatteryWidget: View {
    @ObservedObject var monitor: BatteryMonitor
    private var color: Color {
        if monitor.isCharging { return DN.success }
        if monitor.level <= 20 { return DN.accent }
        return DN.textSecondary
    }

    var body: some View {
        NeutralCard {
            HStack(spacing: DN.spaceSM) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.06), lineWidth: 3).frame(width: 36, height: 36)
                    Circle().trim(from: 0, to: CGFloat(monitor.level) / 100.0)
                        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.4), value: monitor.level)

                    if monitor.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(DN.success)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("BATTERY")
                        .font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)
                    Text("\(monitor.level)%")
                        .font(DN.mono(14, weight: .light)).foregroundColor(DN.textDisplay)
                    if monitor.isCharging {
                        Text("CHARGING")
                            .font(DN.label(6)).tracking(0.8).foregroundColor(DN.success)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: AI Agent Count

struct AgentCountWidget: View {
    @ObservedObject var agentMonitor: AgentMonitor

    private var runningCount: Int {
        agentMonitor.agents.filter { $0.status == .running }.count
    }

    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("AGENTS")
                    .font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)

                HStack(alignment: .bottom, spacing: 4) {
                    Text("\(agentMonitor.agents.count)")
                        .font(DN.mono(28, weight: .light))
                        .foregroundColor(agentMonitor.agents.isEmpty ? DN.textDisabled : DN.textDisplay)

                    if runningCount > 0 {
                        Text("\(runningCount) ACTIVE")
                            .font(DN.label(7)).tracking(0.8)
                            .foregroundColor(DN.warning)
                            .padding(.bottom, 5)
                    }
                }

                // Colored dots per type
                if !agentMonitor.agents.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(agentMonitor.groupedAgents.prefix(4)), id: \.id) { group in
                            Circle()
                                .fill(group.type.brandColor)
                                .frame(width: 5, height: 5)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: RAM (grid-aware)

struct RAMWidget: View {
    @ObservedObject var monitor: SystemStatsMonitor
    private var pct: Double { monitor.ramTotal > 0 ? monitor.ramUsed / monitor.ramTotal : 0 }
    private var color: Color {
        if pct > 0.85 { return DN.accent }
        if pct > 0.6  { return DN.warning }
        return DN.success
    }
    var body: some View {
        NeutralCard {
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
                .animation(.easeOut(duration: 0.5), value: pct)

                VStack(alignment: .leading, spacing: 2) {
                    Text("RAM").font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)
                    Text("\(Int(pct * 100))%").font(DN.mono(14, weight: .light)).foregroundColor(DN.textDisplay)
                    Text(String(format: "%.1f/%.0fGB", monitor.ramUsed/1e9, monitor.ramTotal/1e9))
                        .font(DN.mono(7)).foregroundColor(DN.textDisabled)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: Disk

struct DiskWidget: View {
    @ObservedObject var monitor: SystemStatsMonitor
    private var pct: Double { monitor.diskTotal > 0 ? monitor.diskUsed / monitor.diskTotal : 0 }
    private var color: Color {
        if pct > 0.9  { return DN.accent }
        if pct > 0.75 { return DN.warning }
        return DN.textSecondary
    }
    var body: some View {
        NeutralCard {
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
                    Text("DISK").font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)
                    Text("\(Int(pct * 100))%").font(DN.mono(14, weight: .light)).foregroundColor(DN.textDisplay)
                    Text(String(format: "%.0f/%.0fGB", monitor.diskUsed/1e9, monitor.diskTotal/1e9))
                        .font(DN.mono(7)).foregroundColor(DN.textDisabled)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: Network

struct NetworkWidget: View {
    @ObservedObject var monitor: SystemStatsMonitor
    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold)).foregroundColor(DN.success)
                    Text("DOWN").font(DN.label(6)).tracking(0.8).foregroundColor(DN.textDisabled)
                    Spacer()
                    Text(fmtBytes(monitor.netDown)).font(DN.mono(9, weight: .medium)).foregroundColor(DN.success)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold)).foregroundColor(DN.warning)
                    Text("UP").font(DN.label(6)).tracking(0.8).foregroundColor(DN.textDisabled)
                    Spacer()
                    Text(fmtBytes(monitor.netUp)).font(DN.mono(9, weight: .medium)).foregroundColor(DN.warning)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: Uptime

struct UptimeWidget: View {
    @ObservedObject var monitor: SystemStatsMonitor
    var body: some View {
        NeutralCard {
            HStack(spacing: DN.spaceSM) {
                Image(systemName: "clock").font(.system(size: 14)).foregroundColor(DN.textDisabled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("UPTIME").font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)
                    Text(monitor.uptimeString).font(DN.mono(14, weight: .light)).foregroundColor(DN.textDisplay)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Widget: Processes

struct ProcessWidget: View {
    @ObservedObject var monitor: SystemStatsMonitor
    var body: some View {
        NeutralCard {
            HStack(spacing: DN.spaceSM) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROCESSES").font(DN.label(7)).tracking(1.2).foregroundColor(DN.textDisabled)
                    Text("\(monitor.processes.count)").font(DN.mono(22, weight: .light)).foregroundColor(DN.textDisplay)
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
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// Tracks each chip's midX in the scroll coordinate space
// MARK: - Date strip: scroll state + trackpad interceptor

private final class DateScrollState: ObservableObject {
    @Published var offset: CGFloat = 0
    var daysInMonth: Int = 30
    /// chipW(26) + chipSpacing(4)
    let stride: CGFloat = 30
    /// Published so eventsContent and chip isSelected update immediately without a binding roundtrip
    @Published var currentDay: Int = 1
    var onDateChange: ((Int) -> Void)?
    /// shadow copy: plain var (non-published) — @Published currentDay drives view updates directly
    private var accumulator: CGFloat = 0
    /// Scroll distance (px) needed to advance one date — half a chip stride feels snappy
    private let threshold: CGFloat = 14

    var maxOffset: CGFloat { CGFloat(max(0, daysInMonth - 1)) * stride }

    /// Called on the main thread per scroll event. Advances dates in whole steps only —
    /// no free-form position; always snaps to a date with spring animation.
    func handleDelta(_ dx: CGFloat, isEnd: Bool = false) {
        if isEnd {
            // Lift fingers — ensure we're sitting exactly on a date
            accumulator = 0
            snapToDay(currentDay)
            return
        }
        accumulator += dx
        let steps = Int(accumulator / threshold)
        guard steps != 0 else { return }
        accumulator -= CGFloat(steps) * threshold
        let target = max(1, min(daysInMonth, currentDay + steps))
        guard target != currentDay else { return }
        currentDay = target
        withAnimation(.spring(response: 0.18, dampingFraction: 0.76)) {
            offset = CGFloat(target - 1) * stride
        }
        onDateChange?(target)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
    }

    func snapToDay(_ day: Int) {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            offset = CGFloat(day - 1) * stride
        }
    }

    func scrollTo(day: Int, animated: Bool) {
        currentDay = day
        accumulator = 0
        let target = CGFloat(day - 1) * stride
        if animated {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { offset = target }
        } else {
            offset = target
        }
    }
}

/// Invisible NSView that intercepts horizontal trackpad scroll anywhere over the strip,
/// routes deltas to DateScrollState and consumes the event so SwiftUI doesn't also process it.
private struct DateScrollInterceptor: NSViewRepresentable {
    let state: DateScrollState

    final class Coordinator {
        let state: DateScrollState
        var monitor: Any?
        weak var view: NSView?

        init(state: DateScrollState) { self.state = state }

        func setup(_ v: NSView) {
            view = v
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let v = self.view, let win = v.window else { return event }
                let ms = NSEvent.mouseLocation
                let mw = win.convertPoint(fromScreen: ms)
                let mv = v.convert(mw, from: nil)
                guard v.bounds.contains(mv) else { return event }

                // Consume but ignore momentum — snapping is driven only by direct touch
                if event.momentumPhase != [] {
                    return nil
                }

                let dx = event.scrollingDeltaX
                let dy = event.scrollingDeltaY
                // Only handle predominantly horizontal scroll
                guard abs(dx) > abs(dy) * 0.4, abs(dx) > 0.1 else { return event }

                let isEnd = event.phase == .ended || event.phase == .cancelled
                DispatchQueue.main.async { self.state.handleDelta(-dx, isEnd: isEnd) }
                return nil  // consume — prevent inner views from also reacting
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.setup(v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// Date strip card — hovers to expand upward as ONE card (no layout shift)
struct DateStripCard: View {
    @ObservedObject var events: CalendarEventsMonitor
    @Binding var selectedDay: Int
    var height: CGFloat = 80
    var expandsUpward: Bool = true
    var onDayTapped: (Int) -> Void = { _ in }

    @StateObject private var scroll = DateScrollState()
    @State private var isHovered = false

    private var stripH: CGFloat { height }
    private let expandH: CGFloat = 120
    private let chipW: CGFloat = 26
    private let chipSpacing: CGFloat = 4

    private var cal: Calendar { Calendar.current }
    private var today: Int { cal.component(.day, from: Date()) }
    private var daysInMonth: Int { cal.range(of: .day, in: .month, for: Date())?.count ?? 30 }
    private var monthName: String {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f.string(from: Date()).uppercased()
    }
    private var dayEvents: [EKEvent] { events.eventsByDay[scroll.currentDay] ?? [] }
    private var dayLabel: String {
        var c = cal.dateComponents([.year, .month], from: Date()); c.day = scroll.currentDay
        guard let d = cal.date(from: c) else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f.string(from: d).uppercased()
    }

    var body: some View {
        // Date strip is the fixed base — it never moves
        VStack(alignment: .leading, spacing: 0) {
            Text(monthName)
                .font(.system(size: 7, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.3))
                .padding(.horizontal, 6)
                .padding(.top, 6)

            GeometryReader { outer in
                let leadingPad = outer.size.width / 2 - chipW / 2

                HStack(spacing: chipSpacing) {
                    ForEach(1...daysInMonth, id: \.self) { day in
                        DayChip(
                            day: day,
                            isToday: day == today,
                            isSelected: day == scroll.currentDay,
                            hasEvents: !(events.eventsByDay[day] ?? []).isEmpty
                        ) {
                            scroll.scrollTo(day: day, animated: true)
                            onDayTapped(day)
                        }
                    }
                }
                .frame(minHeight: outer.size.height, alignment: .center)
                .offset(x: leadingPad - scroll.offset)
            }
            .clipped()
            .background(DateScrollInterceptor(state: scroll))
        }
        .frame(maxWidth: .infinity)
        .frame(height: stripH)
        // Card background anchored to the NON-expansion edge, grows in the expansion direction
        .background(alignment: expandsUpward ? .bottom : .top) {
            ZStack {
                neutralCardBg
                GrainOverlay(opacity: 0.35)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
            .frame(height: isHovered ? stripH + expandH : stripH)
        }
        // Events section anchored at the expansion edge, offset outward
        .overlay(alignment: expandsUpward ? .top : .bottom) {
            if isHovered {
                eventsContent
                    .frame(maxWidth: .infinity)
                    .frame(height: expandH)
                    .offset(y: expandsUpward ? -expandH : expandH)
                    .transition(.opacity)
            }
        }
        .shadow(
            color: isHovered ? .black.opacity(0.22) : .clear,
            radius: 14,
            x: 0,
            y: expandsUpward ? -8 : 8
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isHovered)
        .onHover { h in withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { isHovered = h } }
        .onAppear {
            scroll.daysInMonth = daysInMonth
            scroll.currentDay = selectedDay
            scroll.offset = CGFloat(selectedDay - 1) * scroll.stride
            scroll.onDateChange = { day in onDayTapped(day) }
        }
        .onChange(of: selectedDay) { _, day in
            // External change (e.g. calendar grid tap) → animate to new day
            guard day != scroll.currentDay else { return }
            scroll.scrollTo(day: day, animated: true)
        }
    }

    private var eventsContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayLabel)
                .font(.system(size: 7, weight: .semibold))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.3))

            if dayEvents.isEmpty {
                Text("No events")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(dayEvents, id: \.eventIdentifier) { CompactEventRow(event: $0) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DayChip: View {
    let day: Int
    let isToday: Bool
    let isSelected: Bool
    let hasEvents: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var dayLetter: String {
        var c = Calendar.current.dateComponents([.year, .month], from: Date()); c.day = day
        guard let d = Calendar.current.date(from: c) else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEEEE"; return f.string(from: d).uppercased()
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(dayLetter)
                .font(.system(size: 7, weight: .medium))
                .foregroundColor(.white.opacity(isSelected ? 0.9 : 0.3))

            Text("\(day)")
                .font(.system(size: 11, weight: isToday || isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundColor(.white.opacity(isSelected ? 1.0 : isToday ? 0.9 : 0.55))

            Circle()
                .fill(.white.opacity(hasEvents ? (isSelected ? 0.9 : 0.4) : 0))
                .frame(width: 3, height: 3)
        }
        .frame(width: 26)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(isSelected ? 0.12 : isHovered ? 0.06 : isToday ? 0.06 : 0))
                .overlay(
                    isToday && !isSelected ?
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(.white.opacity(0.25), lineWidth: 0.5) : nil
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { action() }
        .handCursor()
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}


private struct CompactEventRow: View {
    let event: EKEvent

    private var timeStr: String {
        if event.isAllDay { return "ALL DAY" }
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: event.startDate).uppercased()
    }

    var body: some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(.white.opacity(0.2))
                .frame(width: 1.5, height: 20)
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Untitled")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                Text(timeStr)
                    .font(.system(size: 7))
                    .foregroundColor(.white.opacity(0.3))
                    .tracking(0.5)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Calendar Events Monitor

class CalendarEventsMonitor: ObservableObject {
    @Published var eventsByDay: [Int: [EKEvent]] = [:]
    private let store = EKEventStore()

    init() {
        requestAccess()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in self?.fetchEvents() }
    }

    func requestAccess() {
        if #available(macOS 14, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            print("[Calendar] status=\(status.rawValue)")
            if status == .fullAccess {
                fetchEvents()
            } else if status == .notDetermined || status.rawValue == 3 /* writeOnly */ {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let granted = try await self.store.requestFullAccessToEvents()
                        print("[Calendar] granted=\(granted)")
                        if granted { DispatchQueue.main.async { self.fetchEvents() } }
                    } catch {
                        print("[Calendar] error=\(error)")
                    }
                }
            } else {
                print("[Calendar] access denied/restricted, status=\(status.rawValue)")
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .authorized {
                fetchEvents()
            } else if status == .notDetermined {
                store.requestAccess(to: .event) { [weak self] granted, _ in
                    if granted { DispatchQueue.main.async { self?.fetchEvents() } }
                }
            }
        }
    }

    func fetchEvents() {
        let cal = Calendar.current
        let now = Date()
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: now)),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let fetched = store.events(matching: predicate)
        print("[Calendar] fetched \(fetched.count) events for \(start) – \(end)")
        var byDay: [Int: [EKEvent]] = [:]
        for event in fetched {
            let day = cal.component(.day, from: event.startDate)
            byDay[day, default: []].append(event)
        }
        DispatchQueue.main.async { self.eventsByDay = byDay }
    }
}

// MARK: - Mini Calendar

struct MiniCalendarView: View {
    let compact: Bool
    @ObservedObject var events: CalendarEventsMonitor

    @State private var hoveredDay: Int? = nil
    @State private var selectedDay: Int? = nil

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
        VStack(spacing: 3) {
            Text(monthName)
                .font(DN.label(7))
                .tracking(1.2)
                .foregroundColor(DN.textDisabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                ScrollViewReader { proxy in
                    HStack(spacing: 1) {
                        ForEach(1...daysInMonth, id: \.self) { day in
                            VStack(spacing: 2) {
                                Text(dayOfWeekLabel(day))
                                    .font(DN.label(5))
                                    .tracking(0.5)
                                    .foregroundColor(day == currentDay ? DN.black : DN.textDisabled)
                                Text("\(day)")
                                    .font(DN.mono(8, weight: day == currentDay ? .bold : .regular))
                                    .foregroundColor(dayColor(day))
                            }
                            .frame(width: 18, height: 24)
                            .background {
                                if day == currentDay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(DN.textDisplay)
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
        VStack(alignment: .leading, spacing: 0) {
            // Month + year header — clear hierarchy, month prominent
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(monthName)
                    .font(DN.heading(13, weight: .semibold))
                    .foregroundColor(DN.textDisplay)
                Text(yearString)
                    .font(DN.body(11))
                    .foregroundColor(DN.textDisabled)
                Spacer()
            }
            .padding(.bottom, 10)

            // Weekday labels — text only, no background (deference principle)
            HStack(spacing: 0) {
                ForEach(daysOfWeek, id: \.self) { d in
                    Text(d)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DN.textDisabled)
                        .frame(maxWidth: .infinity)
                        .frame(height: 16)
                }
            }

            // 1px separator below weekday row
            Rectangle()
                .fill(DN.border)
                .frame(height: 0.5)
                .padding(.bottom, 2)

            // Day grid — GeometryReader for exact square cells
            GeometryReader { geo in
                let cell = geo.size.width / 7
                let rows = buildCalendarDays()

                VStack(spacing: 2) {
                    ForEach(0..<rows.count, id: \.self) { rowIdx in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { col in
                                let day   = rows[rowIdx][col]
                                let isToday    = day == currentDay
                                let isHovered  = hoveredDay == day && day > 0
                                let isSelected = selectedDay == day && day > 0
                                let dayEvents  = day > 0 ? (events.eventsByDay[day] ?? []) : []

                                ZStack {
                                    // Hover / selected background — subtle rounded rect
                                    if isHovered || isSelected {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(isSelected
                                                  ? DN.accent.opacity(0.15)
                                                  : Color.white.opacity(0.06))
                                            .padding(1)
                                    }

                                    VStack(spacing: 2) {
                                        // Day number with today circle (iOS Calendar style)
                                        ZStack {
                                            if isToday {
                                                Circle()
                                                    .fill(DN.accent)
                                                    .frame(width: cell * 0.72, height: cell * 0.72)
                                            }
                                            Text(day > 0 ? "\(day)" : "")
                                                .font(.system(size: 10,
                                                              weight: isToday ? .bold : .regular))
                                                .foregroundColor(
                                                    isToday    ? DN.black :
                                                    isSelected ? DN.accent :
                                                    day > 0    ? dayColor(day) : .clear
                                                )
                                        }

                                        // Event dots (calendar-colored, up to 3)
                                        if !dayEvents.isEmpty {
                                            HStack(spacing: 2) {
                                                ForEach(0..<min(dayEvents.count, 3), id: \.self) { i in
                                                    Circle()
                                                        .fill(Color(nsColor: dayEvents[i].calendar.color))
                                                        .frame(width: 3, height: 3)
                                                }
                                            }
                                        } else {
                                            Color.clear.frame(height: 3)
                                        }
                                    }
                                }
                                .frame(width: cell, height: cell)
                                .onHover { inside in
                                    withAnimation(.easeOut(duration: 0.1)) {
                                        hoveredDay = inside && day > 0 ? day : nil
                                    }
                                }
                                .onTapGesture {
                                    guard day > 0 else { return }
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        selectedDay = selectedDay == day ? nil : day
                                    }
                                }
                                .handCursor()
                            }
                        }
                    }
                }
            }
            .frame(height: CGFloat(buildCalendarDays().count) * (185.0 / 7.0) + CGFloat(buildCalendarDays().count - 1) * 2)

            // Selected day events — slides in below grid
            if let day = selectedDay {
                let dayEvents = events.eventsByDay[day] ?? []
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle()
                        .fill(DN.border)
                        .frame(height: 0.5)
                        .padding(.vertical, 8)

                    if dayEvents.isEmpty {
                        Text("No events")
                            .font(DN.body(10))
                            .foregroundColor(DN.textDisabled)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(dayEvents.prefix(4), id: \.eventIdentifier) { event in
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color(nsColor: event.calendar.color))
                                        .frame(width: 3, height: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.title ?? "Untitled")
                                            .font(DN.body(10, weight: .medium))
                                            .foregroundColor(DN.textPrimary)
                                            .lineLimit(1)
                                        Text(event.isAllDay ? "All day" : eventTimeString(event))
                                            .font(DN.mono(8))
                                            .foregroundColor(DN.textDisabled)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func dayColor(_ day: Int) -> Color {
        if day == currentDay { return DN.black }
        if day < currentDay { return DN.textDisabled }
        return DN.textPrimary
    }

    private func eventTimeString(_ event: EKEvent) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: event.startDate)
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

// MARK: - Widget Card Views
// All follow the NeutralCard visual language: #111111 bg + grain overlay + white 0.07 border
// Big numbers: Cakra-Normal (same as ClockWidget)
// Labels: 7pt semibold, 1.5 tracking, white 0.28 opacity

private func widgetLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 7, weight: .semibold))
        .tracking(1.5)
        .foregroundColor(.white.opacity(0.28))
}

private func widgetNumber(_ text: String, size: CGFloat = 26, color: Color = .white.opacity(0.88)) -> some View {
    Text(text)
        .font(.custom("Cakra-Normal", size: size))
        .foregroundColor(color)
        .monospacedDigit()
}

struct CPUCardWidget: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor

    var body: some View {
        NeutralCard {
            VStack(spacing: 4) {
                widgetNumber("\(Int(statsMonitor.cpuUsage))%", color: cpuColor)
                widgetLabel("CPU")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var cpuColor: Color {
        let u = statsMonitor.cpuUsage
        if u > 80 { return Color(hexStr: "FF6B6B") }
        if u > 50 { return Color(hexStr: "D4A843").opacity(0.9) }
        return .white.opacity(0.88)
    }
}

struct BatteryCardWidget: View {
    @ObservedObject var monitor: BatteryMonitor

    var body: some View {
        NeutralCard {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.1), lineWidth: 4)
                        .frame(width: 38, height: 38)
                    Circle()
                        .trim(from: 0, to: CGFloat(monitor.level) / 100.0)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 38, height: 38)
                    if monitor.isCharging {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hexStr: "D4A843"))
                    } else {
                        Text("\(monitor.level)%")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                widgetLabel("BATTERY")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var ringColor: Color {
        if monitor.isCharging { return Color(hexStr: "D4A843") }
        if monitor.level <= 20 { return Color(hexStr: "FF6B6B") }
        return .white.opacity(0.72)
    }
}

struct AgentCountCardWidget: View {
    @ObservedObject var agentMonitor: AgentMonitor

    private var runningCount: Int {
        agentMonitor.agents.filter { $0.status == .running }.count
    }

    var body: some View {
        NeutralCard {
            VStack(spacing: 4) {
                widgetNumber(
                    "\(agentMonitor.agents.count)",
                    color: runningCount > 0 ? Color(hexStr: "D4A843") : .white.opacity(0.88)
                )
                widgetLabel("AGENTS")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RAMCardWidget: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor

    private var usedGB: String {
        String(format: "%.1f", statsMonitor.ramUsed / 1_073_741_824)
    }
    private var totalGB: String {
        "\(Int(statsMonitor.ramTotal / 1_073_741_824))GB"
    }

    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                widgetNumber(usedGB, size: 24)
                Text("OF \(totalGB)")
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.top, 1)
                Spacer(minLength: 0)
                widgetLabel("MEMORY")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct DiskCardWidget: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor

    private var usedGB: String {
        "\(Int(statsMonitor.diskUsed / 1_073_741_824))GB"
    }
    private var totalGB: String {
        "\(Int(statsMonitor.diskTotal / 1_073_741_824))GB"
    }
    private var fillRatio: CGFloat {
        guard statsMonitor.diskTotal > 0 else { return 0 }
        return CGFloat(statsMonitor.diskUsed / statsMonitor.diskTotal)
    }

    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    widgetNumber(usedGB, size: 20)
                    Text("/ \(totalGB)")
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.28))
                }

                // Fill bar
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08)).frame(height: 3)
                        Capsule()
                            .fill(fillRatio > 0.85 ? Color(hexStr: "FF6B6B") : .white.opacity(0.55))
                            .frame(width: g.size.width * fillRatio, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 6)

                Spacer(minLength: 0)
                widgetLabel("STORAGE")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct NetworkCardWidget: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor

    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                    Text(formatBytes(statsMonitor.netUp))
                        .font(.custom("Cakra-Normal", size: 13))
                        .foregroundColor(.white.opacity(0.82))
                        .monospacedDigit()
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                    Text(formatBytes(statsMonitor.netDown))
                        .font(.custom("Cakra-Normal", size: 13))
                        .foregroundColor(.white.opacity(0.82))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
                widgetLabel("NETWORK")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func formatBytes(_ bps: Double) -> String {
        if bps < 1024 { return "0 KB/s" }
        if bps < 1_048_576 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.1f MB/s", bps / 1_048_576)
    }
}

struct UptimeCardWidget: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor

    private var uptimeStr: String {
        let t = Int(statsMonitor.uptime)
        let h = t / 3600
        let m = (t % 3600) / 60
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        return String(format: "%dh %02dm", h, m)
    }

    var body: some View {
        NeutralCard {
            VStack(spacing: 4) {
                widgetNumber(uptimeStr, size: 18)
                widgetLabel("UPTIME")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProcessesCardWidget: View {
    @ObservedObject var statsMonitor: SystemStatsMonitor

    var body: some View {
        NeutralCard {
            VStack(spacing: 4) {
                widgetNumber("\(statsMonitor.processCount)")
                widgetLabel("PROCESSES")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
