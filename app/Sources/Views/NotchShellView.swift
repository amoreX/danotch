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
        return viewModel.isInTaskOrChat ? 540 : 520
    }

    private var shapeHeight: CGFloat {
        if !expanded { return notchH }
        switch viewModel.viewState {
        case .overview: return notchH + 210
        case .taskList: return notchH + 260
        case .agentChat: return notchH + 320
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

                if viewModel.showSettings {
                    SettingsPanel(viewModel: viewModel)
                        .padding(.top, notchH + 1)
                        .padding(.horizontal, DN.spaceMD)
                        .padding(.bottom, DN.spaceSM)
                        .frame(width: shapeWidth, alignment: .top)
                        .transition(.opacity)
                } else {
                    NotchContentView(viewModel: viewModel)
                        .padding(.top, notchH + 1)
                        .padding(.horizontal, DN.spaceMD)
                        .padding(.bottom, DN.spaceSM)
                        .frame(width: shapeWidth, alignment: .top)
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
        .animation(.easeOut(duration: 0.35), value: expanded)
        .animation(.easeOut(duration: DN.transitionDuration), value: viewModel.viewState)
        .animation(.easeOut(duration: 0.25), value: viewModel.showSettings)
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
                Button(action: {
                    withAnimation(.easeOut(duration: 0.25)) {
                        viewModel.showSettings.toggle()
                    }
                }) {
                    Text("SET")
                        .font(DN.label(9))
                        .tracking(0.8)
                        .foregroundColor(viewModel.showSettings ? DN.textDisplay : DN.textDisabled)
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
        VStack(alignment: .leading, spacing: DN.spaceMD) {
            Text("SETTINGS")
                .font(DN.label(10))
                .tracking(1.5)
                .foregroundColor(DN.textSecondary)

            Text("NO CONFIGURABLE OPTIONS")
                .font(DN.label(9))
                .tracking(0.8)
                .foregroundColor(DN.textDisabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DN.spaceXL)
        }
    }
}
