import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel

    private var isExpanded: Bool {
        viewModel.viewState != .overview
    }

    private var leftWidth: CGFloat {
        isExpanded ? 0 : 185
    }

    private var approvalTasks: [SubagentTask] {
        Array(viewModel.tasks.filter { $0.status == .awaitingApproval }.prefix(2))
    }

    private var approvalIds: Set<String> {
        Set(approvalTasks.map { $0.id })
    }

    private var rightColumnTasks: [SubagentTask] {
        viewModel.tasks.filter { !approvalIds.contains($0.id) && $0.status != .completed }
    }

    private var completedTasks: [SubagentTask] {
        viewModel.tasks.filter { $0.status == .completed }
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
            // Primary: Time — the hero moment
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

            // Secondary: Date
            Text(viewModel.dateString.uppercased())
                .font(DN.label(9))
                .tracking(1.2)
                .foregroundColor(DN.textSecondary)

            Spacer().frame(height: DN.spaceXS)

            if approvalTasks.isEmpty {
                MiniCalendarView(compact: false)
            } else {
                MiniCalendarView(compact: true)
                Spacer().frame(height: DN.spaceXS)
                approvalCards
            }
        }
        .padding(.trailing, DN.spaceSM)
    }

    // MARK: - Approval cards

    private var approvalCards: some View {
        VStack(spacing: DN.spaceXS) {
            ForEach(approvalTasks) { task in
                Button(action: {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .agentChat(task.id)
                    }
                }) {
                    HStack(spacing: DN.spaceXS) {
                        // Red dot — the accent interrupt
                        Circle()
                            .fill(DN.accent)
                            .frame(width: 5, height: 5)

                        Text(task.description ?? task.task)
                            .font(DN.body(10, weight: .medium))
                            .foregroundColor(DN.textPrimary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DN.spaceSM)
                    .padding(.vertical, DN.spaceXS)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DN.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DN.accent.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
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
        }
    }

    // MARK: - Overview right column

    private var overviewRightColumn: some View {
        VStack(alignment: .leading, spacing: DN.spaceSM) {
            // Header: label + counts
            HStack(spacing: 0) {
                Text("AGENTS")
                    .font(DN.label(9))
                    .tracking(1.5)
                    .foregroundColor(DN.textSecondary)

                Spacer()

                statusCounts
            }

            // Active tasks
            VStack(spacing: DN.spaceXS) {
                ForEach(rightColumnTasks) { task in
                    AgentRow(
                        task: task,
                        isCompact: true,
                        activityText: viewModel.activityText(for: task)
                    ) {
                        withAnimation(DN.transition) {
                            viewModel.viewState = .taskList
                        }
                    }
                }
            }

            // Completed
            if !completedTasks.isEmpty {
                Rectangle()
                    .fill(DN.border)
                    .frame(height: 1)

                Text("COMPLETED")
                    .font(DN.label(8))
                    .tracking(1.2)
                    .foregroundColor(DN.textDisabled)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DN.spaceSM) {
                        ForEach(completedTasks) { task in
                            HStack(spacing: DN.spaceXS) {
                                Text("\u{2713}")
                                    .font(DN.mono(9, weight: .bold))
                                    .foregroundColor(DN.success)
                                Text(task.description ?? task.task)
                                    .font(DN.body(10, weight: .medium))
                                    .foregroundColor(DN.textSecondary)
                                    .lineLimit(1)
                                Text(task.durationString)
                                    .font(DN.mono(9))
                                    .foregroundColor(DN.textDisabled)
                            }
                            .padding(.horizontal, DN.spaceSM)
                            .padding(.vertical, DN.spaceXS)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(DN.border, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                statusCounts
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: DN.spaceXS) {
                    ForEach(viewModel.tasks) { task in
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
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status Counts

    private var statusCounts: some View {
        HStack(spacing: DN.spaceSM) {
            if viewModel.delegatedCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(DN.warning).frame(width: 4, height: 4)
                    Text("\(viewModel.delegatedCount)")
                        .font(DN.mono(10, weight: .medium))
                        .foregroundColor(DN.warning)
                }
            }
            if viewModel.approvalCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(DN.accent).frame(width: 4, height: 4)
                    Text("\(viewModel.approvalCount)")
                        .font(DN.mono(10, weight: .medium))
                        .foregroundColor(DN.accent)
                }
            }
            if viewModel.finishedCount > 0 {
                HStack(spacing: 3) {
                    Circle().fill(DN.success).frame(width: 4, height: 4)
                    Text("\(viewModel.finishedCount)")
                        .font(DN.mono(10, weight: .medium))
                        .foregroundColor(DN.success)
                }
            }
        }
    }
}

// MARK: - Agent Row

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
                    // Status indicator — red dot for approvals, colored dot otherwise
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

// MARK: - Activity Text (replaces shimmer with mechanical pulse)

struct ActivityText: View {
    let text: String
    let color: Color
    @State private var phase: Bool = false

    var body: some View {
        HStack(spacing: DN.spaceXS) {
            // Segmented spinner — 3 dots cycling
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
        // Stagger: each dot is slightly offset
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

    // MARK: - Compact (horizontal strip)

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

    // MARK: - Full grid

    private var fullCalendar: some View {
        VStack(spacing: 0) {
            // Header
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

            // Weekday header
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

            // Day grid
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
