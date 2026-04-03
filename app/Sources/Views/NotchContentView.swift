import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    private var isExpanded: Bool {
        viewModel.viewState != .overview
    }

    private var leftWidth: CGFloat {
        isExpanded ? 0 : 185
    }

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: leftWidth)
                .opacity(isExpanded ? 0 : 1)
                .clipped()

            dividerBar
                .opacity(isExpanded ? 0 : 1)
                .scaleEffect(y: isExpanded ? 0.3 : 1)
                .frame(width: isExpanded ? 0 : nil)
                .clipped()

            mainColumn
        }
        .animation(.easeOut(duration: DN.transitionDuration), value: isExpanded)
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: DN.spaceXS) {
            HStack(alignment: .firstTextBaseline, spacing: DN.space2xs) {
                Text(viewModel.timeString)
                    .font(DN.display(32))
                    .foregroundColor(DN.textDisplay)
                    .tracking(-1)

                Text(viewModel.periodString)
                    .font(DN.label(9))
                    .tracking(0.8)
                    .foregroundColor(DN.textDisabled)
            }

            Text(viewModel.dateString.uppercased())
                .font(DN.label(9))
                .tracking(1.2)
                .foregroundColor(DN.textSecondary)

            Spacer().frame(height: DN.spaceXS)

            MiniCalendarView(compact: false)
        }
        .padding(.trailing, DN.spaceSM)
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
        case .stats, .processList, .settings:
            EmptyView()
        }
    }

    // MARK: - Overview right column

    private var overviewRightColumn: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            HStack(spacing: 0) {
                Text("AGENTS")
                    .font(DN.label(9))
                    .tracking(1.5)
                    .foregroundColor(DN.textSecondary)

                Spacer()

                agentStatusCounts
            }

            if viewModel.agentMonitor.agents.isEmpty {
                emptyAgentState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DN.spaceSM) {
                        ForEach(viewModel.agentMonitor.groupedAgents) { group in
                            AgentGroupView(group: group, isCompact: true) { agent in
                                viewModel.agentMonitor.activateAgent(agent)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Full agents column

    private var agentsColumn: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            HStack(spacing: 0) {
                Text("AGENTS")
                    .font(DN.label(9))
                    .tracking(1.5)
                    .foregroundColor(DN.textSecondary)

                Spacer()

                agentStatusCounts
            }

            if viewModel.agentMonitor.agents.isEmpty && viewModel.tasks.isEmpty {
                emptyAgentState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: DN.spaceSM) {
                        ForEach(viewModel.agentMonitor.groupedAgents) { group in
                            AgentGroupView(group: group, isCompact: false) { agent in
                                viewModel.agentMonitor.activateAgent(agent)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status Counts

    private var agentStatusCounts: some View {
        HStack(spacing: DN.spaceSM) {
            let running = viewModel.agentMonitor.agents.filter { $0.status == .running }.count
            let total = viewModel.agentMonitor.agents.count

            if total > 0 {
                HStack(spacing: 3) {
                    Circle().fill(running > 0 ? DN.warning : DN.textDisabled).frame(width: 4, height: 4)
                    Text("\(running)")
                        .font(DN.mono(10, weight: .medium))
                        .foregroundColor(running > 0 ? DN.warning : DN.textDisabled)

                    Text("/")
                        .font(DN.mono(9))
                        .foregroundColor(DN.textDisabled)

                    Text("\(total)")
                        .font(DN.mono(10, weight: .medium))
                        .foregroundColor(DN.textDisabled)
                }
            }
        }
    }
}

// MARK: - Agent Group View

struct AgentGroupView: View {
    let group: AgentGroup
    let isCompact: Bool
    let onTapAgent: (DetectedAgent) -> Void

    @State private var isExpanded: Bool = true

    private var canCollapse: Bool { group.agents.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header — tappable to toggle if multiple agents
            Button(action: {
                guard canCollapse else { return }
                withAnimation(.easeOut(duration: DN.microDuration)) {
                    isExpanded.toggle()
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
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .padding(.horizontal, DN.spaceSM)
                .padding(.vertical, DN.spaceXS + 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Agent rows — collapsible
            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(group.agents) { agent in
                        AgentSessionRow(agent: agent, isCompact: isCompact) {
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
                if agent.liveState != .idle && agent.liveState != .waitingForUser {
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
            .padding(.vertical, DN.spaceXS + 1)
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
            .padding(.vertical, isCompact ? 5 : 7)
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
        .background(DN.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DN.border, lineWidth: 1)
        )
    }

    private func dayColor(_ day: Int) -> Color {
        if day == currentDay { return DN.black }
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
