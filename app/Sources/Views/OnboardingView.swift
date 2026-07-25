import SwiftUI

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

    static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private enum LocalOnboardingStep: Int, CaseIterable {
    case welcome
    case provider

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .provider: return "Provider"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var viewModel: NotchViewModel
    let onWindowSizeChange: (CGSize) -> Void
    let onComplete: () -> Void

    @State private var step: LocalOnboardingStep = .welcome
    @State private var userName = ""
    @State private var provider = "anthropic"
    @State private var apiKey = ""
    @State private var model = ProviderConfig.defaultModels["anthropic"] ?? ""
    @State private var baseURL = ""
    @State private var composioKey = ""
    @State private var isSavingProvider = false

    private let size = CGSize(width: 620, height: 430)

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
            userName = viewModel.settings.userName
            viewModel.loadProviderConfigs()
            viewModel.loadComposioState()
        }
        .onReceive(viewModel.$providerConfigs) { configs in
            guard let active = configs.first(where: \.isActive) else { return }
            provider = active.provider
            model = active.modelId
            baseURL = active.baseURL ?? ""
        }
        .onChange(of: provider) { _, newProvider in
            if let saved = viewModel.providerConfigs.first(where: { $0.provider == newProvider }) {
                model = saved.modelId
                baseURL = saved.baseURL ?? ""
            } else {
                model = ProviderConfig.defaultModels[newProvider] ?? "default"
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
                Text("Welcome to Perch.")
                    .font(.system(size: 38, weight: .light, design: .rounded))
                Text("Everything runs on this Mac. What should Perch call you?")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                TextField("Your name", text: $userName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                Label(viewModel.connectionState.detail, systemImage: viewModel.connectionState.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(connectionColor)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard(cornerRadius: 14)
            }
        case .provider:
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    "Connect a provider",
                    "Choose a provider and enter its API key. Perch uses a recommended default model; you can change models later in Settings."
                )
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
                if provider == "custom" {
                    TextField("OpenAI-compatible base URL", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                SecureField("Composio API key (optional)", text: $composioKey)
                    .textFieldStyle(.roundedBorder)
                if let active = viewModel.providerConfigs.first(where: {
                    $0.provider == provider && $0.isActive
                }) {
                    Label(
                        "Using saved \(active.displayName) configuration",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(DN.success)
                } else if let error = viewModel.providerError[provider] ?? nil {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(DN.accent)
                } else if viewModel.providerVerified[provider] == true {
                    Label("Verified by the local daemon", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(DN.success)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step == .provider {
                Button("Back") { step = .welcome }
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
                .disabled(
                    apiKey.isEmpty
                        || (provider == "custom" && normalizedBaseURL == nil)
                        || viewModel.providerVerifying[provider] == true
                )
            }
            Button(
                step == .provider
                    ? (isSavingProvider ? "Saving…" : "Open Perch")
                    : "Continue"
            ) {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .tint(DN.activeAccent)
            .disabled(!canContinue || isSavingProvider)
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome:
            guard !trimmedName.isEmpty else { return false }
            if case .connected = viewModel.connectionState { return true }
            return false
        case .provider:
            return viewModel.providerVerified[provider] == true
                || viewModel.providerConfigs.contains {
                    $0.provider == provider && $0.isActive
                }
        }
    }

    private var trimmedName: String {
        userName.trimmingCharacters(in: .whitespacesAndNewlines)
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
            viewModel.settings.userName = trimmedName
            step = .provider
        case .provider:
            if viewModel.providerConfigs.contains(where: {
                $0.provider == provider && $0.isActive
            }), apiKey.isEmpty {
                finishOnboarding()
                return
            }
            guard !apiKey.isEmpty, viewModel.providerVerified[provider] == true else { return }
            isSavingProvider = true
            let submittedKey = apiKey
            viewModel.saveProviderConfig(
                provider: provider,
                apiKey: submittedKey,
                modelId: model,
                baseURL: normalizedBaseURL
            ) { saved in
                isSavingProvider = false
                guard saved else { return }
                apiKey = ""
                finishOnboarding()
            }
        }
    }

    private func finishOnboarding() {
            if !composioKey.isEmpty {
                viewModel.configureComposio(apiKey: composioKey)
                composioKey = ""
            }
            OnboardingCompletionStore.markComplete()
            onComplete()
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
}
