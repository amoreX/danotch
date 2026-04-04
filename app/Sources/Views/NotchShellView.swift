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
        if !expanded { return notchW }
        switch viewModel.viewState {
        case .taskList, .agentChat: return 540
        case .processList: return 540
        case .stats: return 520
        case .settings: return 520
        case .overview: return 520
        }
    }

    private var shapeHeight: CGFloat {
        if !expanded { return notchH }
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
        expanded ? 16 : 8
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape

            if expanded {
                // Interactive dot grid behind content
                DotGridView()
                    .padding(.top, notchH)
                    .opacity(0.6)
                    .allowsHitTesting(false)

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.35), value: expanded)
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

            HStack(spacing: DN.spaceMD) {
                tabButton(
                    label: "STATS",
                    isActive: viewModel.viewState == .stats || viewModel.viewState == .processList
                ) {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .stats
                    }
                }

                Button(action: {
                    withAnimation(DN.transition) {
                        viewModel.viewState = .settings
                    }
                }) {
                    Image(systemName: viewModel.viewState == .settings ? "gearshape.fill" : "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(viewModel.viewState == .settings ? DN.textDisplay : DN.textDisabled)
                        .padding(DN.spaceXS)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                BatteryView()
            }
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
                    SettingsSection(title: "BEHAVIOR") {
                        SettingsToggleRow(
                            icon: "arrow.right.circle",
                            title: "Navigate to agent on tap",
                            subtitle: "Tapping an agent row opens its detail page",
                            isOn: $viewModel.settings.tapAgentNavigates
                        )
                        SettingsToggleRow(
                            icon: "cursorarrow.motionlines",
                            title: "Expand on hover",
                            subtitle: "Automatically expand panel when hovering over notch",
                            isOn: $viewModel.settings.expandOnHover
                        )
                    }

                    SettingsSection(title: "DISPLAY") {
                        SettingsToggleRow(
                            icon: "calendar",
                            title: "Show calendar",
                            subtitle: "Display mini calendar in the overview",
                            isOn: $viewModel.settings.showCalendar
                        )
                        SettingsToggleRow(
                            icon: "arrow.up.left.and.arrow.down.right",
                            title: "Large calendar",
                            subtitle: "Use expanded calendar layout",
                            isOn: $viewModel.settings.largeCalendar
                        )
                        SettingsToggleRow(
                            icon: "music.note",
                            title: "Show now playing",
                            subtitle: "Display current music track in overview",
                            isOn: $viewModel.settings.showMusic
                        )
                        SettingsToggleRow(
                            icon: "battery.75percent",
                            title: "Show battery",
                            subtitle: "Display battery indicator in the top bar",
                            isOn: $viewModel.settings.showBattery
                        )
                        SettingsToggleRow(
                            icon: "circle.grid.3x3",
                            title: "Animated dot grid",
                            subtitle: "Show animated dot matrix background",
                            isOn: $viewModel.settings.showDotGrid
                        )
                    }

                    SettingsSection(title: "AGENTS") {
                        SettingsToggleRow(
                            icon: "waveform",
                            title: "Show live state",
                            subtitle: "Display real-time tool activity for agents",
                            isOn: $viewModel.settings.showAgentLiveState
                        )
                        SettingsToggleRow(
                            icon: "rectangle.compress.vertical",
                            title: "Compact agent rows",
                            subtitle: "Use smaller rows in the agent list",
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
