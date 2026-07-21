import SwiftUI
import UserNotifications

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case account
    case model
    case apps
    case permissions
    case preferences
    case success

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .account: return "Account"
        case .model: return "Model"
        case .apps: return "Apps"
        case .permissions: return "Permissions"
        case .preferences: return "Preferences"
        case .success: return "Ready"
        }
    }

    var windowSize: CGSize {
        switch self {
        case .welcome, .success:
            return CGSize(width: 360, height: 360)
        case .account, .model, .apps, .permissions, .preferences:
            return CGSize(width: 700, height: 560)
        }
    }

    var setupIndex: Int? {
        switch self {
        case .account: return 1
        case .model: return 2
        case .apps: return 3
        case .permissions: return 4
        case .preferences: return 5
        case .welcome, .success: return nil
        }
    }
}

enum OnboardingCompletionStore {
    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".danotch")
    private static let configFile = configDir.appendingPathComponent("onboarding.json")
    static let currentVersion = 1

    static var isComplete: Bool {
        guard let data = try? Data(contentsOf: configFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["completed"] as? Bool == true && (json["version"] as? Int ?? 0) >= currentVersion
    }

    static func markComplete(settings: [String: Any]) {
        var payload = settings
        payload["completed"] = true
        payload["version"] = currentVersion
        payload["completed_at"] = ISO8601DateFormatter().string(from: Date())

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFile)
        } catch {
            print("[Onboarding] Failed to save completion: \(error)")
        }
    }
}

// MARK: - Constants

private enum OB {
    static let outerRadius: CGFloat = 20
    static let sidebarWidth: CGFloat = 160
    static let contentPadding: CGFloat = 28
    static let cardRadius: CGFloat = 14
    static let cardInnerRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 10
    static let buttonHeight: CGFloat = 34
    static let inputHeight: CGFloat = 40
    static let sectionSpacing: CGFloat = 20
    static let itemSpacing: CGFloat = 8
    static let accent = Color(hex: 0x8B7CF6)
    static let accentSubtle = Color(hex: 0x8B7CF6).opacity(0.25)
}

struct OnboardingView: View {
    @ObservedObject var auth: AuthManager
    @ObservedObject var viewModel: NotchViewModel
    let onWindowSizeChange: (CGSize) -> Void
    let onComplete: () -> Void

    @State private var step: OnboardingStep
    @State private var contentVisible = true
    @State private var authMode: AuthMode = .signup
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""

    @State private var useDefaultModel = true
    @State private var selectedProvider = "anthropic"
    @State private var apiKey = ""
    @State private var selectedModel = ProviderConfig.defaultModels["anthropic"] ?? ""

    @State private var localToolConsent = true
    @State private var agentMonitoring = true
    @State private var musicControls = true
    @State private var systemNotifications = true
    @State private var automationCheckComplete = false

    @State private var selectedWidgets: Set<PinnedWidget> = [.calendar, .music]
    @State private var openChatOnSend = true
    @State private var keepOpenInChat = true
    @State private var restoreLastView = false

    init(
        auth: AuthManager,
        viewModel: NotchViewModel,
        onWindowSizeChange: @escaping (CGSize) -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.auth = auth
        self.viewModel = viewModel
        self.onWindowSizeChange = onWindowSizeChange
        self.onComplete = onComplete
        _step = State(initialValue: auth.isAuthenticated ? .model : .welcome)
    }

    private var isSetupStep: Bool {
        step != .welcome && step != .success
    }

    var body: some View {
        ZStack {
            onboardingBackground

            if isSetupStep {
                setupShell
            } else {
                Group {
                    switch step {
                    case .welcome: welcomeStep
                    case .success: successStep
                    default: EmptyView()
                    }
                }
                .opacity(contentVisible ? 1 : 0)
                .scaleEffect(contentVisible ? 1 : 0.992)
                .animation(.easeOut(duration: 0.16), value: contentVisible)
            }
        }
        .frame(width: step.windowSize.width, height: step.windowSize.height)
        .clipShape(RoundedRectangle(cornerRadius: OB.outerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OB.outerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onAppear {
            viewModel.authManager = auth
            onWindowSizeChange(step.windowSize)
            if auth.isAuthenticated { loadSetupState() }
        }
        .onChange(of: step) { _, newStep in
            onWindowSizeChange(newStep.windowSize)
            if newStep != .welcome && auth.isAuthenticated { loadSetupState() }
        }
        .onChange(of: selectedProvider) { _, provider in
            selectedModel = ProviderConfig.defaultModels[provider] ?? ""
        }
    }

    private var onboardingBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color(hex: 0x071014).opacity(0.7),
                    Color.black.opacity(0.65),
                    Color(hex: 0x061513).opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [Color.white.opacity(0.05), .clear], center: .topLeading, startRadius: 20, endRadius: 280)
            RadialGradient(colors: [Color(hex: 0x0D3730).opacity(0.25), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Perch")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("The only assistant you'll ever need")
                .font(.system(size: 20, weight: .regular, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Spacer()

            HStack {
                Spacer()
                pillButton("Get Started", style: .accent) { go(.account) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 40)
    }

    // MARK: - Setup Shell

    private var setupShell: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 20) {
                Text("Perch")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach([OnboardingStep.account, .model, .apps, .permissions, .preferences], id: \.self) { item in
                        stepRow(item)
                    }
                }

                Spacer()
            }
            .padding(16)
            .frame(width: OB.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.025))

            // Content + Footer
            VStack(spacing: 0) {
                Group {
                    switch step {
                    case .account: accountStep
                    case .model: modelStep
                    case .apps: appsStep
                    case .permissions: permissionsStep
                    case .preferences: preferencesStep
                    default: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(contentVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: contentVisible)

                footer
            }
            .padding(.horizontal, OB.contentPadding)
            .padding(.top, OB.contentPadding)
            .padding(.bottom, OB.contentPadding + 14)
        }
    }

    private func stepRow(_ item: OnboardingStep) -> some View {
        let active = item == step
        let done = (item.setupIndex ?? 0) < (step.setupIndex ?? 0)
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(done ? OB.accent.opacity(0.7) : (active ? OB.accent.opacity(0.85) : Color.white.opacity(0.06)))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(item.setupIndex ?? 0)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(active ? .white : .secondary)
                }
            }

            Text(item.title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .white : Color.white.opacity(0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 32)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .account && step != .model {
                pillButton("Back", icon: "chevron.left", style: .glass) { go(previousStep) }
            }

            Spacer()

            pillButton(
                step == .preferences ? "Finish Setup" : "Continue",
                style: .accent,
                loading: step == .account && auth.isLoading
            ) {
                advance()
            }
            .disabled(!canContinue)
            .opacity(canContinue ? 1 : 0.4)
        }
        .padding(.top, OB.sectionSpacing)
    }

    // MARK: - Account

    private enum AuthMode { case signup, login }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: OB.sectionSpacing) {
            pageHeader("Create your account", "Sync setup, save chat history, and unlock scheduled tasks.")

            HStack(spacing: OB.itemSpacing) {
                modeTab("Sign up", selected: authMode == .signup) {
                    authMode = .signup; auth.error = nil; auth.lifecycleState = .credentials
                }
                modeTab("Sign in", selected: authMode == .login) {
                    authMode = .login; auth.error = nil; auth.lifecycleState = .credentials
                }
            }

            if case .checkEmail(let pendingEmail) = auth.lifecycleState {
                verificationPanel(email: pendingEmail.isEmpty ? email : pendingEmail)
            } else if case .verificationExpired(let pendingEmail) = auth.lifecycleState {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Verification link expired", systemImage: "clock.badge.exclamationmark")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Reopen secure signup to resend verification, or use a different email address.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack {
                        pillButton("Resend in browser", icon: "safari", style: .accent) {
                            auth.reopenBrowserSignup(email: pendingEmail)
                        }
                        pillButton("Change email", style: .glass) {
                            email = ""
                            auth.lifecycleState = .credentials
                        }
                    }
                }
                .padding(14)
                .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
            } else if auth.lifecycleState == .repairProvisioning {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your email is verified, but account setup needs another attempt.", systemImage: "arrow.clockwise.circle")
                    Text("Sign in again to repair the profile, app bootstrap, and trial idempotently.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(14)
                .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
            } else {
                VStack(spacing: OB.itemSpacing) {
                    if authMode == .signup {
                        inputField("Email", text: $email, icon: "envelope")
                        Text("Signup opens in your browser so the CAPTCHA and verification flow stay on the trusted HTTPS origin.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        inputField("Email", text: $email, icon: "envelope")
                        inputField("Password", text: $password, icon: "lock", isSecure: true)
                    }
                }
            }

            if let error = auth.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(OB.accent)
                    .lineLimit(2)
            }
        }
    }

    private func verificationPanel(email: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Check your email", systemImage: "envelope.badge")
                .font(.system(size: 15, weight: .semibold))
            Text("Open the verification link on this Mac or another device. Then return here and sign in.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                pillButton("Reopen signup", icon: "safari", style: .glass) {
                    auth.reopenBrowserSignup(email: email)
                }
                pillButton("I've verified", icon: "checkmark.circle", style: .accent) {
                    self.email = email
                    authMode = .login
                    auth.returnToSignIn(email: email)
                }
                pillButton("Change email", style: .glass) {
                    self.email = ""
                    auth.lifecycleState = .credentials
                }
            }
        }
        .padding(14)
        .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
    }

    // MARK: - Model

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: OB.sectionSpacing) {
            pageHeader("Choose your model", "Use Perch's default or bring your own provider key.")

            VStack(spacing: OB.itemSpacing) {
                optionCard(
                    title: "Use Perch default",
                    subtitle: "Start immediately with the server-configured model.",
                    icon: "server.rack",
                    selected: useDefaultModel
                ) { useDefaultModel = true }

                optionCard(
                    title: "Bring your own key",
                    subtitle: "Anthropic, OpenAI, or OpenRouter. Keys encrypted at rest.",
                    icon: "key.fill",
                    selected: !useDefaultModel
                ) { useDefaultModel = false }
            }

            if !useDefaultModel {
                providerSetup
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if activeProvider != nil {
                configuredProviderNotice
            }
        }
        .onAppear { viewModel.loadProviderConfigs() }
    }

    private var providerSetup: some View {
        VStack(alignment: .leading, spacing: OB.itemSpacing) {
            Picker("Provider", selection: $selectedProvider) {
                Text("Anthropic").tag("anthropic")
                Text("OpenAI").tag("openai")
                Text("OpenRouter").tag("openrouter")
            }
            .pickerStyle(.segmented)
            .tint(OB.accent)

            inputField("API key", text: .init(get: { apiKey }, set: { apiKey = $0 }), icon: "key", isSecure: true)

            HStack(spacing: OB.itemSpacing) {
                Picker("Model", selection: $selectedModel) {
                    ForEach(ProviderConfig.availableModels[selectedProvider] ?? [], id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Spacer()

                pillButton(isVerifyingProvider ? "Verifying…" : "Verify", icon: "checkmark.shield", style: .glass) {
                    viewModel.verifyProviderKey(provider: selectedProvider, apiKey: apiKey, modelId: selectedModel)
                }
                .disabled(apiKey.isEmpty || isVerifyingProvider)
                .opacity(apiKey.isEmpty ? 0.4 : 1)
            }

            if isProviderVerified {
                Label("Verified — saved when you continue.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OB.accent)
            } else if let error = providerError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(OB.accent)
            }
        }
        .padding(OB.cardRadius)
        .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
    }

    private var configuredProviderNotice: some View {
        Label("\(activeProvider?.displayName ?? "Provider") is already configured.", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(OB.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
    }

    // MARK: - Apps

    private var appsStep: some View {
        VStack(alignment: .leading, spacing: OB.sectionSpacing) {
            pageHeader("Connect your apps", "Optional — Perch can request connections later.")

            LazyVGrid(columns: [GridItem(.flexible(), spacing: OB.itemSpacing), GridItem(.flexible(), spacing: OB.itemSpacing)], spacing: OB.itemSpacing) {
                ForEach(appIntegrations, id: \.appType) { app in
                    appCard(app)
                }
            }
        }
        .onAppear {
            for app in appIntegrations { viewModel.checkAppStatus(app.appType) }
        }
    }

    @State private var appActionInProgress: Set<String> = []

    private func appCard(_ app: IntegrationInfo) -> some View {
        let connected = viewModel.appConnected[app.appType] ?? false
        let loading = appActionInProgress.contains(app.appType)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Group {
                    if app.icon == "github" {
                        GitHubMark()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: app.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                .frame(width: 30, height: 30)
                .perchGlass(in: Circle())
                Spacer()
                if connected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(OB.accent)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(app.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let error = viewModel.appError[app.appType] ?? nil {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .lineLimit(1)
            }

            Button(action: {
                appActionInProgress.insert(app.appType)
                if connected { viewModel.disconnectApp(app.appType) }
                else { viewModel.connectApp(app.appType) }
            }) {
                HStack(spacing: 5) {
                    if loading { ProgressView().controlSize(.small) }
                    Text(connected ? "Disconnect" : "Connect")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: OB.cardInnerRadius, style: .continuous))
                .perchGlass(
                    tint: connected ? nil : OB.accentSubtle,
                    in: RoundedRectangle(cornerRadius: OB.cardInnerRadius)
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(loading)
        }
        .padding(12)
        .frame(minHeight: 150)
        .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
        .onChange(of: viewModel.appLoading[app.appType]) { _, isLoading in
            if isLoading == false || isLoading == nil {
                appActionInProgress.remove(app.appType)
            }
        }
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: OB.sectionSpacing) {
            pageHeader("Approve local access", "Choose what Perch can use on this Mac.")

            VStack(spacing: OB.itemSpacing) {
                permissionRow(title: "Agent monitoring", subtitle: "Show active AI sessions, CPU, memory, and project.", icon: "cpu", isOn: $agentMonitoring)
                permissionRow(title: "Music controls", subtitle: "Read and control Apple Music for the media widget.", icon: "music.note", isOn: $musicControls)
                permissionRow(title: "Notifications", subtitle: "macOS alerts for scheduled tasks and updates.", icon: "bell.badge", isOn: $systemNotifications)
            }
        }
    }

    private func permissionRow(title: String, subtitle: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .perchGlass(in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .focusable(false)
                .tint(OB.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
    }

    // MARK: - Preferences

    private var preferencesStep: some View {
        VStack(alignment: .leading, spacing: OB.sectionSpacing) {
            pageHeader("Tune the notch", "Pick overview widgets and default chat behavior.")

            VStack(alignment: .leading, spacing: OB.itemSpacing) {
                Text("PINNED WIDGETS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .tracking(1)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(PinnedWidget.allCases, id: \.rawValue) { widget in
                        widgetChip(widget)
                    }
                }
            }
            .padding(12)
            .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))

            VStack(spacing: OB.itemSpacing) {
                prefToggle("Open chat after sending", $openChatOnSend)
                prefToggle("Keep chat open on hover", $keepOpenInChat)
                prefToggle("Restore last view", $restoreLastView)
            }
        }
    }

    private func widgetChip(_ widget: PinnedWidget) -> some View {
        let selected = selectedWidgets.contains(widget)
        let atMax = !selected && selectedWidgets.count >= 3

        return Button(action: {
            guard !atMax else { return }
            if selected { selectedWidgets.remove(widget) }
            else { selectedWidgets.insert(widget) }
        }) {
            HStack(spacing: 6) {
                Image(systemName: widget.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(widget.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? .white : .secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(RoundedRectangle(cornerRadius: OB.cardInnerRadius, style: .continuous))
            .perchGlass(
                tint: selected ? OB.accentSubtle : nil,
                in: RoundedRectangle(cornerRadius: OB.cardInnerRadius)
            )
            .opacity(atMax ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(atMax)
    }

    private func prefToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .focusable(false)
                .tint(OB.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardRadius))
    }

    // MARK: - Success

    private var successStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .perchGlass(tint: OB.accent.opacity(0.6), in: Circle())

            Text("You're ready")
                .font(.system(size: 42, weight: .light, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 24)

            Text("Perch is configured. Hover near the notch to open the assistant.")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .padding(.top, 10)

            Spacer()

            HStack {
                Spacer()
                pillButton("Start", style: .accent) {
                    OnboardingCompletionStore.markComplete(settings: completionPayload)
                    onComplete()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
    }

    // MARK: - Shared Components

    private func pageHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private enum PillStyle { case accent, glass }

    private func pillButton(_ title: String, icon: String? = nil, style: PillStyle, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if loading {
                    ProgressView().controlSize(.small).tint(.white)
                }
                if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: OB.buttonHeight)
            .contentShape(RoundedRectangle(cornerRadius: OB.buttonRadius, style: .continuous))
            .background {
                if style == .accent {
                    RoundedRectangle(cornerRadius: OB.buttonRadius, style: .continuous)
                        .fill(OB.accent.opacity(0.75))
                        .overlay(
                            RoundedRectangle(cornerRadius: OB.buttonRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                }
            }
            .perchGlass(
                tint: style == .glass ? nil : .clear,
                in: RoundedRectangle(cornerRadius: OB.buttonRadius)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .focusable(false)
    }

    private func modeTab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .white : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: OB.buttonHeight)
                .contentShape(RoundedRectangle(cornerRadius: OB.buttonRadius, style: .continuous))
                .perchGlass(
                    tint: selected ? OB.accentSubtle : nil,
                    in: RoundedRectangle(cornerRadius: OB.buttonRadius)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .focusable(false)
    }

    private func optionCard(title: String, subtitle: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .perchGlass(in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? OB.accent : Color.white.opacity(0.2))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: OB.cardRadius, style: .continuous))
            .perchGlass(
                tint: selected ? OB.accentSubtle : nil,
                in: RoundedRectangle(cornerRadius: OB.cardRadius)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .focusable(false)
    }

    private func inputField(_ placeholder: String, text: Binding<String>, icon: String, isSecure: Bool = false) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 32)

            Group {
                if isSecure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: OB.inputHeight)
        .frame(maxWidth: .infinity)
        .padding(.trailing, 12)
        .perchGlass(in: RoundedRectangle(cornerRadius: OB.cardInnerRadius))
    }

    // MARK: - Flow

    private var previousStep: OnboardingStep {
        switch step {
        case .model: return .account
        case .apps: return .model
        case .permissions: return .apps
        case .preferences: return .permissions
        default: return .welcome
        }
    }

    private var canSubmitAuth: Bool {
        if authMode == .signup { return !email.isEmpty }
        return !email.isEmpty && !password.isEmpty
    }

    private var canContinue: Bool {
        switch step {
        case .account:
            if case .checkEmail = auth.lifecycleState { return false }
            if case .verificationExpired = auth.lifecycleState { return false }
            return canSubmitAuth && !auth.isLoading
        case .model: return useDefaultModel || isProviderVerified || activeProvider != nil
        case .permissions: return true
        default: return true
        }
    }

    private var activeProvider: ProviderConfig? {
        viewModel.providerConfigs.first { $0.isActive }
    }

    private var isVerifyingProvider: Bool {
        viewModel.providerVerifying[selectedProvider] ?? false
    }

    private var isProviderVerified: Bool {
        viewModel.providerVerified[selectedProvider] ?? false
    }

    private var providerError: String? {
        viewModel.providerError[selectedProvider] ?? nil
    }

    private func go(_ next: OnboardingStep) {
        guard next != step else { return }
        withAnimation(.easeOut(duration: 0.12)) { contentVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            step = next
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeOut(duration: 0.18)) { contentVisible = true }
            }
        }
    }

    private func advance() {
        switch step {
        case .account: performAuth()
        case .model:
            if !useDefaultModel && !apiKey.isEmpty && isProviderVerified {
                viewModel.saveProviderConfig(provider: selectedProvider, apiKey: apiKey, modelId: selectedModel)
                apiKey = ""
            }
            go(.apps)
        case .apps: go(.permissions)
        case .permissions:
            if systemNotifications { requestNotificationPermission() }
            if musicControls { requestMusicAutomation() }
            go(.preferences)
        case .preferences:
            applyPreferences()
            go(.success)
        default: break
        }
    }

    private func performAuth() {
        Task {
            let success: Bool
            if authMode == .signup {
                success = await auth.signup(email: email, password: password, fullName: fullName)
            } else {
                success = await auth.login(email: email, password: password)
            }
            if success {
                await MainActor.run {
                    viewModel.authManager = auth
                    loadSetupState()
                    go(.model)
                }
            }
        }
    }

    private func loadSetupState() {
        viewModel.loadProviderConfigs()
        for app in appIntegrations { viewModel.checkAppStatus(app.appType) }
    }

    private func applyPreferences() {
        viewModel.settings.openChatOnSend = openChatOnSend
        viewModel.settings.keepOpenInChat = keepOpenInChat
        viewModel.settings.restoreLastView = restoreLastView
        viewModel.settings.pinnedWidgets = orderedSelectedWidgets.prefix(3).map { $0 }
    }

    private var orderedSelectedWidgets: [PinnedWidget] {
        PinnedWidget.allCases.filter { selectedWidgets.contains($0) }
    }

    private var completionPayload: [String: Any] {
        [
            "local_tool_consent": localToolConsent,
            "agent_monitoring": agentMonitoring,
            "music_controls": musicControls,
            "system_notifications": systemNotifications,
            "use_default_model": useDefaultModel,
            "selected_provider": selectedProvider,
            "connected_apps": appIntegrations.filter { viewModel.appConnected[$0.appType] == true }.map { $0.appType },
            "pinned_widgets": orderedSelectedWidgets.map { $0.rawValue },
            "open_chat_on_send": openChatOnSend,
            "keep_open_in_chat": keepOpenInChat,
            "restore_last_view": restoreLastView,
        ]
    }

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func requestMusicAutomation() {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            try
                if application "Music" is running then
                    tell application "Music" to get player state
                end if
                if application "Spotify" is running then
                    tell application "Spotify" to get player state
                end if
            end try
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async { automationCheckComplete = true }
        }
    }
}

private struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let ox = rect.midX - 8 * s
        let oy = rect.midY - 8 * s
        var p = Path()
        p.move(to: CGPoint(x: ox + 8*s, y: oy))
        p.addCurve(to: CGPoint(x: ox, y: oy + 8*s), control1: CGPoint(x: ox + 3.58*s, y: oy), control2: CGPoint(x: ox, y: oy + 3.58*s))
        p.addCurve(to: CGPoint(x: ox + 5.47*s, y: oy + 15.59*s), control1: CGPoint(x: ox, y: oy + 11.54*s), control2: CGPoint(x: ox + 2.29*s, y: oy + 14.53*s))
        p.addCurve(to: CGPoint(x: ox + 6.02*s, y: oy + 15.21*s), control1: CGPoint(x: ox + 5.87*s, y: oy + 15.66*s), control2: CGPoint(x: ox + 6.02*s, y: oy + 15.4*s))
        p.addLine(to: CGPoint(x: ox + 6.01*s, y: oy + 13.72*s))
        p.addCurve(to: CGPoint(x: ox + 3.33*s, y: oy + 12.78*s), control1: CGPoint(x: ox + 4*s, y: oy + 14.09*s), control2: CGPoint(x: ox + 3.48*s, y: oy + 13.72*s))
        p.addCurve(to: CGPoint(x: ox + 2.51*s, y: oy + 11.65*s), control1: CGPoint(x: ox + 3.24*s, y: oy + 12.55*s), control2: CGPoint(x: ox + 2.99*s, y: oy + 11.88*s))
        p.addCurve(to: CGPoint(x: ox + 2.52*s, y: oy + 11.12*s), control1: CGPoint(x: ox + 2.23*s, y: oy + 11.5*s), control2: CGPoint(x: ox + 1.89*s, y: oy + 11.11*s))
        p.addCurve(to: CGPoint(x: ox + 3.75*s, y: oy + 11.94*s), control1: CGPoint(x: ox + 3.15*s, y: oy + 11.13*s), control2: CGPoint(x: ox + 3.6*s, y: oy + 11.7*s))
        p.addCurve(to: CGPoint(x: ox + 6.08*s, y: oy + 12.6*s), control1: CGPoint(x: ox + 4.47*s, y: oy + 13.15*s), control2: CGPoint(x: ox + 5.62*s, y: oy + 12.81*s))
        p.addCurve(to: CGPoint(x: ox + 6.59*s, y: oy + 11.53*s), control1: CGPoint(x: ox + 6.15*s, y: oy + 12.35*s), control2: CGPoint(x: ox + 6.31*s, y: oy + 11.73*s))
        p.addCurve(to: CGPoint(x: ox + 2.94*s, y: oy + 7.58*s), control1: CGPoint(x: ox + 4.81*s, y: oy + 11.33*s), control2: CGPoint(x: ox + 2.94*s, y: oy + 10.53*s))
        p.addCurve(to: CGPoint(x: ox + 3.76*s, y: oy + 5.43*s), control1: CGPoint(x: ox + 2.94*s, y: oy + 6.71*s), control2: CGPoint(x: ox + 3.25*s, y: oy + 5.99*s))
        p.addCurve(to: CGPoint(x: ox + 3.84*s, y: oy + 3.31*s), control1: CGPoint(x: ox + 3.68*s, y: oy + 5.23*s), control2: CGPoint(x: ox + 3.4*s, y: oy + 4.41*s))
        p.addCurve(to: CGPoint(x: ox + 6.04*s, y: oy + 4.13*s), control1: CGPoint(x: ox + 3.84*s, y: oy + 3.31*s), control2: CGPoint(x: ox + 4.51*s, y: oy + 3.09*s))
        p.addCurve(to: CGPoint(x: ox + 10.04*s, y: oy + 4.13*s), control1: CGPoint(x: ox + 6.68*s, y: oy + 3.95*s), control2: CGPoint(x: ox + 9.36*s, y: oy + 3.95*s))
        p.addCurve(to: CGPoint(x: ox + 12.24*s, y: oy + 3.31*s), control1: CGPoint(x: ox + 11.57*s, y: oy + 3.09*s), control2: CGPoint(x: ox + 12.24*s, y: oy + 3.31*s))
        p.addCurve(to: CGPoint(x: ox + 12.32*s, y: oy + 5.43*s), control1: CGPoint(x: ox + 12.68*s, y: oy + 4.41*s), control2: CGPoint(x: ox + 12.4*s, y: oy + 5.23*s))
        p.addCurve(to: CGPoint(x: ox + 13.14*s, y: oy + 7.58*s), control1: CGPoint(x: ox + 12.83*s, y: oy + 5.99*s), control2: CGPoint(x: ox + 13.14*s, y: oy + 6.85*s))
        p.addCurve(to: CGPoint(x: ox + 9.49*s, y: oy + 11.53*s), control1: CGPoint(x: ox + 13.14*s, y: oy + 10.65*s), control2: CGPoint(x: ox + 11.27*s, y: oy + 11.33*s))
        p.addCurve(to: CGPoint(x: ox + 10.03*s, y: oy + 13.01*s), control1: CGPoint(x: ox + 9.78*s, y: oy + 11.78*s), control2: CGPoint(x: ox + 10.03*s, y: oy + 12.26*s))
        p.addLine(to: CGPoint(x: ox + 10.02*s, y: oy + 15.21*s))
        p.addCurve(to: CGPoint(x: ox + 10.57*s, y: oy + 15.59*s), control1: CGPoint(x: ox + 10.02*s, y: oy + 15.42*s), control2: CGPoint(x: ox + 10.17*s, y: oy + 15.66*s))
        p.addCurve(to: CGPoint(x: ox + 16*s, y: oy + 8*s), control1: CGPoint(x: ox + 13.71*s, y: oy + 14.53*s), control2: CGPoint(x: ox + 16*s, y: oy + 11.54*s))
        p.addCurve(to: CGPoint(x: ox + 8*s, y: oy), control1: CGPoint(x: ox + 16*s, y: oy + 3.58*s), control2: CGPoint(x: ox + 12.42*s, y: oy))
        p.closeSubpath()
        return p
    }
}

private struct IntegrationInfo {
    let appType: String
    let name: String
    let icon: String
    let description: String
}

private let appIntegrations: [IntegrationInfo] = [
    IntegrationInfo(appType: "gmail", name: "Gmail", icon: "paperplane", description: "Summaries, search, drafts, and scheduled inbox checks."),
    IntegrationInfo(appType: "googlecalendar", name: "Calendar", icon: "calendar.badge.clock", description: "Daily agenda, event lookup, and scheduling workflows."),
    IntegrationInfo(appType: "googledocs", name: "Docs", icon: "doc.richtext", description: "Read, write, and summarize Google Docs."),
    IntegrationInfo(appType: "github", name: "GitHub", icon: "github", description: "Issues, pull requests, repositories, and code context."),
]
