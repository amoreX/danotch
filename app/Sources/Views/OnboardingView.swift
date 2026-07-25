import SwiftUI
import UserNotifications

enum OnboardingCompletionStore {
    private static let fileURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0]
        .appendingPathComponent("Perch", isDirectory: true)
        .appendingPathComponent("onboarding.json")
    static let currentVersion = 2

    static var isComplete: Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["completed"] as? Bool == true
            && (json["version"] as? Int ?? 0) >= currentVersion
    }

    static func markComplete() {
        let payload: [String: Any] = [
            "completed": true,
            "version": currentVersion,
            "completed_at": ISO8601DateFormatter().string(from: Date()),
        ]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Completion is convenience state, never secret material.
        }
    }
}

private enum LocalOnboardingStep: Int, CaseIterable {
    case welcome
    case provider
    case localAccess

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .provider: return "Provider"
        case .localAccess: return "Local access"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var viewModel: NotchViewModel
    let onWindowSizeChange: (CGSize) -> Void
    let onComplete: () -> Void

    @State private var step: LocalOnboardingStep = .welcome
    @State private var provider = "anthropic"
    @State private var apiKey = ""
    @State private var model = ProviderConfig.defaultModels["anthropic"] ?? ""
    @State private var baseURL = ""
    @State private var composioKey = ""
    @State private var notifications = true

    private let size = CGSize(width: 620, height: 480)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 22) {
                content
                Spacer(minLength: 8)
                footer
            }
            .padding(28)
        }
        .frame(width: size.width, height: size.height)
        .background(Color(hex: 0x080A0C))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .onAppear {
            onWindowSizeChange(size)
            viewModel.loadProviderConfigs()
            viewModel.loadComposioState()
        }
        .onChange(of: provider) { _, newProvider in
            model = ProviderConfig.defaultModels[newProvider] ?? ""
            if newProvider == "deepseek", baseURL.isEmpty {
                baseURL = "https://api.deepseek.com"
            } else if newProvider != "custom" && newProvider != "deepseek" {
                baseURL = ""
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("PERCH")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .tracking(2)
            ForEach(LocalOnboardingStep.allCases, id: \.rawValue) { item in
                HStack(spacing: 9) {
                    Circle()
                        .fill(item.rawValue <= step.rawValue ? DN.activeAccent : Color.white.opacity(0.12))
                        .frame(width: 7, height: 7)
                    Text(item.title)
                        .font(.system(size: 12, weight: item == step ? .semibold : .regular))
                        .foregroundStyle(item == step ? .white : .secondary)
                }
            }
            Spacer()
            Text("LOCAL-FIRST")
                .font(DN.label(9))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 150)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.025))
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 18) {
                Text("Your assistant,\non this Mac.")
                    .font(.system(size: 38, weight: .light, design: .rounded))
                Text("Perch talks to a local daemon over an authenticated loopback session. Conversations stay partitioned by this installation and no cloud relay is required.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(viewModel.connectionState.detail, systemImage: viewModel.connectionState.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(connectionColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(cornerRadius: 14)
            }
        case .provider:
            VStack(alignment: .leading, spacing: 14) {
                pageHeader("Connect a model", "Credentials go directly to the authenticated local daemon. Perch never writes them to settings or files.")
                Picker("Provider", selection: $provider) {
                    Text("Anthropic").tag("anthropic")
                    Text("OpenAI").tag("openai")
                    Text("OpenRouter").tag("openrouter")
                    Text("DeepSeek").tag("deepseek")
                    Text("Compatible").tag("custom")
                }
                .pickerStyle(.segmented)
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $model)
                    .textFieldStyle(.roundedBorder)
                if provider == "custom" || provider == "deepseek" {
                    TextField("Base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("Composio API key (optional)", text: $composioKey)
                    .textFieldStyle(.roundedBorder)
                if let error = viewModel.providerError[provider] ?? nil {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DN.accent)
                } else if viewModel.providerVerified[provider] == true {
                    Label("Verified by the local daemon", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(DN.success)
                }
            }
        case .localAccess:
            VStack(alignment: .leading, spacing: 16) {
                pageHeader("Choose local access", "You can change these later in Settings.")
                permissionToggle(
                    "Agent monitoring",
                    detail: "See active coding-agent sessions and local resource use.",
                    isOn: $viewModel.settings.agentMonitoringEnabled
                )
                permissionToggle(
                    "Music controls",
                    detail: "Read and control Apple Music for the notch widget.",
                    isOn: $viewModel.settings.musicControlsEnabled
                )
                permissionToggle(
                    "Native notifications",
                    detail: "Show scheduled-task results through macOS.",
                    isOn: $notifications
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    step = LocalOnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            if step == .provider {
                Button(viewModel.providerVerifying[provider] == true ? "Verifying…" : "Verify") {
                    viewModel.verifyProviderKey(
                        provider: provider,
                        apiKey: apiKey,
                        modelId: model,
                        baseURL: normalizedBaseURL
                    )
                }
                .buttonStyle(.bordered)
                .disabled(apiKey.isEmpty || model.isEmpty || viewModel.providerVerifying[provider] == true)
            }
            Button(step == .localAccess ? "Open Perch" : "Continue") {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .tint(DN.activeAccent)
            .disabled(!canContinue)
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome:
            if case .connected = viewModel.connectionState { return true }
            return false
        case .provider:
            return viewModel.providerVerified[provider] == true
                || viewModel.providerConfigs.contains(where: { $0.isActive })
        case .localAccess:
            return true
        }
    }

    private var normalizedBaseURL: String? {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private var connectionColor: Color {
        if case .connected = viewModel.connectionState { return DN.success }
        if case .offline = viewModel.connectionState { return DN.accent }
        return DN.warning
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .provider
        case .provider:
            if !apiKey.isEmpty, viewModel.providerVerified[provider] == true {
                viewModel.saveProviderConfig(
                    provider: provider,
                    apiKey: apiKey,
                    modelId: model,
                    baseURL: normalizedBaseURL
                )
                apiKey = ""
            }
            if !composioKey.isEmpty {
                viewModel.configureComposio(apiKey: composioKey)
                composioKey = ""
            }
            step = .localAccess
        case .localAccess:
            viewModel.settings.systemNotificationsEnabled = notifications
            if notifications, Bundle.main.bundleIdentifier != nil {
                UNUserNotificationCenter.current().requestAuthorization(
                    options: [.alert, .sound, .badge]
                ) { granted, _ in
                    if !granted {
                        DispatchQueue.main.async {
                            viewModel.settings.systemNotificationsEnabled = false
                        }
                    }
                }
            }
            OnboardingCompletionStore.markComplete()
            onComplete()
        }
    }

    private func pageHeader(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionToggle(
        _ title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(12)
        .contentCard(cornerRadius: 14)
    }
}
