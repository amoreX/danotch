import SwiftUI
import AppKit
import IOKit.ps

struct NotchShellView: View {
    @ObservedObject var viewModel: NotchViewModel

    // Separate width/height expansion state so they can be staggered
    @State private var wideExpanded = false
    @State private var tallExpanded = false

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    private var notchW: CGFloat { screen.notchWidth }
    private var notchH: CGFloat { screen.notchHeight }
    private var expanded: Bool { viewModel.isExpanded }

    private var shapeWidth: CGFloat {
        if !wideExpanded { return notchW }
        if !viewModel.isAuthenticated { return 520 }
        switch viewModel.viewState {
        case .taskList, .agentChat: return 540
        case .processList: return 540
        case .stats: return 520
        case .settings: return 520
        case .overview: return 520
        }
    }

    private var shapeHeight: CGFloat {
        if !tallExpanded { return notchH }
        if !viewModel.isAuthenticated { return notchH + 260 }
        switch viewModel.viewState {
        case .overview: return notchH + 260
        case .taskList: return notchH + 260
        case .agentChat: return notchH + 320
        case .stats: return notchH + 290
        case .processList: return notchH + 320
        case .settings: return notchH + 320
        }
    }

    private var bottomRadius: CGFloat {
        wideExpanded ? 16 : 8
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape

            if expanded {
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
                        .padding(.horizontal, DN.spaceMD)
                        .padding(.bottom, DN.spaceSM)
                        .frame(width: shapeWidth, alignment: .top)
                } else {
                    NotchAuthView(auth: AuthManager.shared)
                        .padding(.top, notchH + 1)
                        .padding(.horizontal, DN.spaceMD)
                        .padding(.bottom, DN.spaceSM)
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
        .onHover { hovering in
            viewModel.mouseInContent = hovering
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Width: snappy spring, expands first / collapses last
        // Width: easeOut only — spring would undershoot and expose background behind the panel
        .animation(.easeOut(duration: 0.2), value: wideExpanded)
        // Height: spring for the jelly feel — undershoot here is hidden by the menu bar
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: tallExpanded)
        // Content fade + border
        .animation(.easeOut(duration: 0.15), value: expanded)
        // Tab / view state switches
        .animation(.easeOut(duration: 0.18), value: viewModel.viewState)
        .onChange(of: viewModel.isExpanded) { _, isNowExpanded in
            if isNowExpanded {
                // Width opens first, height follows 50ms later
                wideExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    tallExpanded = true
                }
            } else {
                // Height closes first, width follows 40ms later
                tallExpanded = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    wideExpanded = false
                }
            }
        }
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
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DN.black)
                .frame(height: 1)
        }
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
