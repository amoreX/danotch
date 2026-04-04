import SwiftUI

enum OnboardingStep {
    case welcome
    case signup
    case login
}

struct OnboardingView: View {
    @ObservedObject var auth: AuthManager
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""

    var body: some View {
        ZStack {
            DN.black.ignoresSafeArea()

            VStack(spacing: 0) {
                switch step {
                case .welcome:
                    welcomeStep
                case .signup:
                    authStep(isSignup: true)
                case .login:
                    authStep(isSignup: false)
                }
            }
            .frame(width: 360, height: 440)
        }
        .frame(width: 360, height: 440)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: DN.spaceLG) {
            Spacer()

            Text("DANOTCH")
                .font(DN.display(28))
                .tracking(6)
                .foregroundColor(DN.textDisplay)

            Text("WELCOME TO THE NOTCH")
                .font(DN.label(10))
                .tracking(2)
                .foregroundColor(DN.textDisabled)

            Spacer()

            Button(action: {
                withAnimation(.easeOut(duration: DN.transitionDuration)) {
                    step = .signup
                }
            }) {
                Text("START")
                    .font(DN.label(11))
                    .tracking(2)
                    .foregroundColor(DN.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(DN.textDisplay)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DN.spaceXL)
            .padding(.bottom, DN.spaceXL)
        }
    }

    // MARK: - Auth (signup / login)

    private func authStep(isSignup: Bool) -> some View {
        VStack(spacing: DN.spaceMD) {
            Spacer().frame(height: DN.spaceLG)

            Text(isSignup ? "CREATE ACCOUNT" : "SIGN IN")
                .font(DN.label(12))
                .tracking(2)
                .foregroundColor(DN.textDisplay)

            Text(isSignup ? "Get started with Danotch" : "Welcome back")
                .font(DN.body(12))
                .foregroundColor(DN.textDisabled)

            Spacer().frame(height: DN.spaceSM)

            VStack(spacing: DN.spaceSM) {
                if isSignup {
                    inputField("Full Name", text: $fullName, icon: "person")
                }
                inputField("Email", text: $email, icon: "envelope")
                inputField("Password", text: $password, icon: "lock", isSecure: true)
            }
            .padding(.horizontal, DN.spaceXL)

            if let error = auth.error {
                Text(error)
                    .font(DN.mono(9))
                    .foregroundColor(DN.accent)
                    .padding(.horizontal, DN.spaceXL)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: DN.spaceSM) {
                Button(action: { performAuth(isSignup: isSignup) }) {
                    Group {
                        if auth.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(DN.black)
                        } else {
                            Text(isSignup ? "SIGN UP" : "SIGN IN")
                                .font(DN.label(11))
                                .tracking(2)
                                .foregroundColor(DN.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(canSubmit ? DN.textDisplay : DN.textDisabled)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || auth.isLoading)

                Button(action: {
                    withAnimation(.easeOut(duration: DN.microDuration)) {
                        auth.error = nil
                        if isSignup { step = .login } else { step = .signup }
                    }
                }) {
                    Text(isSignup ? "Already have an account? **Sign in**" : "New here? **Sign up**")
                        .font(DN.body(11))
                        .foregroundColor(DN.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DN.spaceXL)
            .padding(.bottom, DN.spaceXL)
        }
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (step != .signup || !fullName.isEmpty)
    }

    private func performAuth(isSignup: Bool) {
        Task {
            let success: Bool
            if isSignup {
                success = await auth.signup(email: email, password: password, fullName: fullName)
            } else {
                success = await auth.login(email: email, password: password)
            }
            if success {
                await MainActor.run { onComplete() }
            }
        }
    }

    // MARK: - Input field

    private func inputField(_ placeholder: String, text: Binding<String>, icon: String, isSecure: Bool = false) -> some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DN.textDisabled)
                .frame(width: 16)

            if isSecure {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(DN.body(12))
                    .foregroundColor(DN.textPrimary)
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(DN.body(12))
                    .foregroundColor(DN.textPrimary)
            }
        }
        .padding(.horizontal, DN.spaceSM + 4)
        .padding(.vertical, 12)
        .background(DN.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(DN.border, lineWidth: 1)
        )
    }
}
