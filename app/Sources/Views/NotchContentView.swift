import SwiftUI
import EventKit

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @State private var chatInputText: String = ""
    @FocusState private var isChatInputFocused: Bool

    private var isExpanded: Bool {
        viewModel.viewState != .overview
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
        .animation(.easeOut(duration: 0.15), value: isExpanded)
        .animation(.easeOut(duration: 0.15), value: viewModel.viewState)
        .onChange(of: viewModel.shouldFocusChatInput) { _, shouldFocus in
            if shouldFocus {
                isChatInputFocused = true
                viewModel.shouldFocusChatInput = false
            }
        }
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)

            // Music card — 3/4 width
            GeometryReader { geo in
                MusicPlayerCard(monitor: viewModel.nowPlaying)
                    .frame(width: geo.size.width * 0.75, height: musicCardH)
                    .clipped()
            }
            .frame(height: musicCardH)
            .clipped()

            // Two half-width calendar cards
            HStack(spacing: 6) {
                DateStripCard(events: viewModel.calendarEvents, selectedDay: $calSelectedDay)
                EventsCard(events: viewModel.calendarEvents, selectedDay: calSelectedDay)
            }
            .frame(height: 80)

            clockCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var calSelectedDay: Int = Calendar.current.component(.day, from: Date())

    private let musicCardH: CGFloat = 70

    // Outer notch bottomRadius=16, content gap=4 → inner bottom = 16-4 = 12
    private let clockCardShape = UnevenRoundedRectangle(
        topLeadingRadius: 8, bottomLeadingRadius: 12,
        bottomTrailingRadius: 12, topTrailingRadius: 8,
        style: .continuous
    )

    private var clockCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(viewModel.timeString)
                    .font(.custom("Cakra-Normal", size: 44))
                    .foregroundColor(Color(hexStr: "e8e4f4"))
                    .tracking(-1)

                Text(viewModel.periodString)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .foregroundColor(Color(hexStr: "e8e4f4").opacity(0.45))
            }

            Text(viewModel.dateString.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.5)
                .foregroundColor(Color(hexStr: "e8e4f4").opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let pal = viewModel.wallpaper.palette
            ZStack {
                RadialGradient(
                    colors: [pal.dark, pal.mid],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 380
                )
                RadialGradient(
                    colors: [pal.accent.opacity(0.22), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 160
                )
                GrainOverlay(opacity: 0.5)
            }
            .animation(.easeInOut(duration: 0.8), value: viewModel.wallpaper.palette)
        }
        .clipShape(clockCardShape)
        .overlay(clockCardShape.stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: - Pinned Widget Router

    @ViewBuilder
    private func pinnedWidgetView(_ widget: PinnedWidget) -> some View {
        switch widget {
        case .calendar:
            MiniCalendarView(compact: viewModel.settings.pinnedWidgets.count > 1, events: viewModel.calendarEvents)
        case .music:
            NowPlayingView(
                monitor: viewModel.nowPlaying,
                isBig: viewModel.settings.musicSize == .big,
                accentColor: viewModel.settings.dotGridSwiftColor
            )
        case .ram:
            PinnedRAMView(monitor: viewModel.statsMonitor)
        case .disk:
            PinnedDiskView(monitor: viewModel.statsMonitor)
        case .network:
            PinnedNetworkView(monitor: viewModel.statsMonitor)
        case .uptime:
            PinnedUptimeView(monitor: viewModel.statsMonitor)
        case .processes:
            PinnedProcessView(monitor: viewModel.statsMonitor)
        }
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

    private var timer: Timer?
    private var positionTimer: Timer?
    private var positionBase: Double = 0
    private var positionTimestamp: Date = Date()

    var progress: Double { duration > 0 ? position / duration : 0 }

    func timeString(_ seconds: Double) -> String {
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: MediaRemote types
    private typealias MRGetNowPlayingFn  = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRGetPlaybackFn    = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias MRSendCommandFn    = @convention(c) (UInt32, AnyObject?) -> Bool
    private typealias MRRegisterFn       = @convention(c) (DispatchQueue) -> Void
    private var mrGetInfo:     MRGetNowPlayingFn?
    private var mrGetPlayback: MRGetPlaybackFn?
    private var mrSendCmd:     MRSendCommandFn?

    // MediaRemote command constants
    private let kMRPlay:     UInt32 = 0
    private let kMRPause:    UInt32 = 1
    private let kMRToggle:   UInt32 = 2
    private let kMRNextTrack: UInt32 = 4
    private let kMRPrevTrack: UInt32 = 5

    init() {
        loadMediaRemote()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Interpolate position every 0.5s while playing
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying, self.duration > 0 else { return }
            let elapsed = Date().timeIntervalSince(self.positionTimestamp)
            self.position = min(self.positionBase + elapsed, self.duration)
        }
    }

    deinit {
        timer?.invalidate()
        positionTimer?.invalidate()
    }

    private func loadMediaRemote() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else { return }
        // Must register BEFORE calling GetNowPlayingInfo, otherwise it returns empty
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            let register = unsafeBitCast(ptr, to: MRRegisterFn.self)
            register(DispatchQueue.main)
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) {
            mrGetInfo = unsafeBitCast(ptr, to: MRGetNowPlayingFn.self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationPlaybackStateForBundleID" as CFString) {
            mrGetPlayback = unsafeBitCast(ptr, to: MRGetPlaybackFn.self)
        }
        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            mrSendCmd = unsafeBitCast(ptr, to: MRSendCommandFn.self)
        }
    }

    func poll() {
        guard let mrGetInfo else { fallbackPoll(); return }
        mrGetInfo(DispatchQueue.main) { [weak self] info in
            guard let self else { return }
            let newTrack  = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String
            let newArtist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String
            let newDur    = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
            let newPos    = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
            let playing   = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0

            let trackChanged = newTrack != self.track
            self.track    = newTrack
            self.artist   = newArtist
            self.duration = newDur
            self.isPlaying = playing
            self.positionBase = newPos
            self.positionTimestamp = Date()
            if playing { self.position = newPos }

            // Artwork
            if trackChanged {
                if let artData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data,
                   let img = NSImage(data: artData) {
                    self.artworkImage = img
                } else {
                    self.artworkImage = nil
                }
            }
            if newTrack == nil { self.artworkImage = nil }
        }
    }

    // Fallback: osascript for Apple Music
    private func fallbackPoll() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
                            return t & "|||" & a & "|||" & s & "|||" & p & "|||" & d
                        end if
                    end tell
                end if
            end try
            return ""
            """
            let pipe = Pipe(); let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = pipe; proc.standardError = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !out.isEmpty else {
                DispatchQueue.main.async { self?.track = nil; self?.artist = nil; self?.artworkImage = nil }
                return
            }
            let p = out.components(separatedBy: "|||")
            DispatchQueue.main.async {
                self?.track    = p.count > 0 ? p[0] : nil
                self?.artist   = p.count > 1 ? p[1] : nil
                self?.isPlaying = p.count > 2 && p[2] == "playing"
                self?.position = p.count > 3 ? Double(p[3]) ?? 0 : 0
                self?.duration = p.count > 4 ? Double(p[4]) ?? 0 : 0
            }
        }
    }

    // MARK: Playback control
    func runCommand(_ cmd: String) {
        // Try MediaRemote first
        switch cmd {
        case "playpause":
            if let fn = mrSendCmd { _ = fn(kMRToggle, nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }; return }
        case "next track":
            if let fn = mrSendCmd { _ = fn(kMRNextTrack, nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }; return }
        case "previous track":
            if let fn = mrSendCmd { _ = fn(kMRPrevTrack, nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }; return }
        default: break
        }
        // Fallback: osascript Apple Music
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let script = "try\nif application \"Music\" is running then\ntell application \"Music\" to \(cmd)\nend if\nend try"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
            try? proc.run(); proc.waitUntilExit()
            Thread.sleep(forTimeInterval: 0.3)
            self?.poll()
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

// MARK: - Music Player Card

private struct MusicPlayerCard: View {
    @ObservedObject var monitor: NowPlayingMonitor
    @State private var isShuffling = false
    private let h: CGFloat = 70

    var body: some View {
        NeutralCard {
            HStack(spacing: 0) {

                // Cover art — fills full height, square, edge-to-edge on left
                Group {
                    if let img = monitor.artworkImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.04)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.15))
                            )
                    }
                }
                .frame(width: h, height: h)
                .clipped()

                // Track info + progress bar
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(monitor.track ?? "Nothing Playing")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                        Text(monitor.artist ?? "—")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.38))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1)).frame(height: 2)
                            Capsule().fill(Color.white.opacity(0.65))
                                .frame(width: max(0, geo.size.width * CGFloat(monitor.progress)), height: 2)
                        }
                    }
                    .frame(height: 2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)

                // 3 square control buttons — 5+18+3+18+3+18+5 = 70px ✓
                VStack(spacing: 3) {
                    MusicSquareButton(icon: monitor.isPlaying ? "pause.fill" : "play.fill") {
                        monitor.runCommand("playpause")
                    }
                    MusicSquareButton(icon: "forward.end.fill") {
                        monitor.runCommand("next track")
                    }
                    MusicSquareButton(icon: "shuffle", active: isShuffling) {
                        isShuffling.toggle()
                        monitor.runCommand("set shuffle enabled to \(isShuffling)")
                    }
                }
                .padding(.trailing, 6)
                .padding(.vertical, 5)
            }
        }
    }
}

private struct MusicSquareButton: View {
    let icon: String
    var active: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(active ? .white : .white.opacity(isHovered ? 0.85 : 0.5))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(active ? 0.15 : isHovered ? 0.08 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .handCursor()
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

// Left card: horizontal date strip
struct DateStripCard: View {
    @ObservedObject var events: CalendarEventsMonitor
    @Binding var selectedDay: Int

    private var cal: Calendar { Calendar.current }
    private var today: Int { cal.component(.day, from: Date()) }
    private var daysInMonth: Int { cal.range(of: .day, in: .month, for: Date())?.count ?? 30 }
    private var monthName: String {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f.string(from: Date()).uppercased()
    }

    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 5) {
                Text(monthName)
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.3))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(1...daysInMonth, id: \.self) { day in
                            DayChip(
                                day: day,
                                isToday: day == today,
                                isSelected: day == selectedDay,
                                hasEvents: !(events.eventsByDay[day] ?? []).isEmpty
                            ) { selectedDay = day }
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }
}

// Right card: events for selected day
struct EventsCard: View {
    @ObservedObject var events: CalendarEventsMonitor
    let selectedDay: Int

    private var cal: Calendar { Calendar.current }
    private var dayEvents: [EKEvent] { events.eventsByDay[selectedDay] ?? [] }
    private var dayLabel: String {
        var c = cal.dateComponents([.year, .month], from: Date()); c.day = selectedDay
        guard let d = cal.date(from: c) else { return "" }
        let f = DateFormatter(); f.dateFormat = "EEE d"; return f.string(from: d).uppercased()
    }

    var body: some View {
        NeutralCard {
            VStack(alignment: .leading, spacing: 5) {
                Text(dayLabel)
                    .font(.system(size: 7, weight: .semibold))
                    .tracking(1.5)
                    .foregroundColor(.white.opacity(0.3))

                if dayEvents.isEmpty {
                    Spacer(minLength: 0)
                    Text("No events")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.2))
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(dayEvents, id: \.eventIdentifier) { event in
                                CompactEventRow(event: event)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
