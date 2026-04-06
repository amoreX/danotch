import SwiftUI

// MARK: - Notch-native auth view (compact, fits within the notch expanded area)

enum AuthStep {
    case welcome
    case signup
    case login
}

struct NotchAuthView: View {
    @ObservedObject var auth: AuthManager

    @State private var step: AuthStep = .welcome
    @State private var email = ""
    @State private var password = ""
    @State private var fullName = ""

    var body: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .signup:
            authStep(isSignup: true)
        case .login:
            authStep(isSignup: false)
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: DN.spaceSM) {
                Text("DANOTCH")
                    .font(DN.display(26))
                    .tracking(6)
                    .foregroundColor(DN.textDisplay)

                Text("WELCOME TO THE NOTCH")
                    .font(DN.label(9))
                    .tracking(2)
                    .foregroundColor(DN.textDisabled)
            }

            Spacer()

            Button(action: {
                withAnimation(.easeOut(duration: DN.transitionDuration)) {
                    step = .signup
                }
            }) {
                Text("GET STARTED")
                    .font(DN.label(10))
                    .tracking(2)
                    .foregroundColor(DN.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(DN.textDisplay)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Auth (signup / login)

    private func authStep(isSignup: Bool) -> some View {
        VStack(spacing: DN.spaceSM) {
            Text(isSignup ? "CREATE ACCOUNT" : "SIGN IN")
                .font(DN.label(11))
                .tracking(2)
                .foregroundColor(DN.textDisplay)

            Spacer().frame(height: 2)

            VStack(spacing: 6) {
                if isSignup {
                    inputField("Full Name", text: $fullName, icon: "person")
                }
                inputField("Email", text: $email, icon: "envelope")
                inputField("Password", text: $password, icon: "lock", isSecure: true)
            }

            if let error = auth.error {
                Text(error)
                    .font(DN.mono(9))
                    .foregroundColor(DN.accent)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
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
                                .font(DN.label(10))
                                .tracking(2)
                                .foregroundColor(DN.black)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(canSubmit ? DN.textDisplay : DN.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || auth.isLoading)

                Button(action: {
                    withAnimation(.easeOut(duration: DN.microDuration)) {
                        auth.error = nil
                        step = isSignup ? .login : .signup
                    }
                }) {
                    Text(isSignup ? "Already have an account? Sign in" : "New here? Sign up")
                        .font(DN.body(10))
                        .foregroundColor(DN.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canSubmit: Bool {
        !email.isEmpty && !password.isEmpty && (step != .signup || !fullName.isEmpty)
    }

    private func performAuth(isSignup: Bool) {
        Task {
            if isSignup {
                _ = await auth.signup(email: email, password: password, fullName: fullName)
            } else {
                _ = await auth.login(email: email, password: password)
            }
            // View reactively dismisses when auth.isAuthenticated flips
        }
    }

    // MARK: - Input field

    private func inputField(_ placeholder: String, text: Binding<String>, icon: String, isSecure: Bool = false) -> some View {
        HStack(spacing: DN.spaceSM) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DN.textDisabled)
                .frame(width: 14)

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
        .padding(.horizontal, DN.spaceSM + 2)
        .padding(.vertical, 9)
        .background(DN.surface)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(DN.border, lineWidth: 1)
        )
    }
}
