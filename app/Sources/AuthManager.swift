import Foundation
import SwiftUI
import AppKit

enum AuthLifecycleState: Equatable {
    case credentials
    case browserSignup
    case checkEmail(String)
    case verificationExpired(String)
    case crossDeviceVerified(String)
    case repairProvisioning
}

struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int?
    var userId: String
    var email: String
    var fullName: String
}

enum RefreshFailureDisposition: Equatable {
    case preserveSession
    case logout

    static func classify(statusCode: Int, code: String?) -> Self {
        statusCode == 401 && code == "invalid_refresh_token" ? .logout : .preserveSession
    }
}

class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var session: AuthSession?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var error: String?
    @Published var lifecycleState: AuthLifecycleState = .credentials

    var onSessionWillChange: ((String?, String?) -> Void)?
    var onSessionDidChange: ((AuthSession?) -> Void)?

    private let sessionStore: SecureSessionStore
    private let accountDataStore: AccountDataStore
    private var baseURL: String { APIConfig.baseURL }

    var userName: String {
        session?.fullName ?? session?.email.components(separatedBy: "@").first ?? ""
    }

    var accessToken: String? { session?.accessToken }

    init(
        sessionStore: SecureSessionStore = SecureSessionStore(),
        accountDataStore: AccountDataStore = AccountDataStore()
    ) {
        self.sessionStore = sessionStore
        self.accountDataStore = accountDataStore
        loadSession()
    }

    // MARK: - Signup

    func signup(email: String, password: String, fullName: String) async -> Bool {
        await MainActor.run {
            isLoading = false
            error = nil
            lifecycleState = .browserSignup
        }
        var components = URLComponents(string: baseURL + "/auth/signup/browser")
        components?.queryItems = [URLQueryItem(name: "email", value: email)]
        guard let url = components?.url else {
            await MainActor.run { error = "Could not open secure signup." }
            return false
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        await MainActor.run {
            if opened {
                lifecycleState = .checkEmail(email)
            } else {
                error = "Could not open your browser. Check your default browser and try again."
                lifecycleState = .credentials
            }
        }
        return false
    }

    // MARK: - Login

    func login(email: String, password: String) async -> Bool {
        await MainActor.run { isLoading = true; error = nil }

        let body: [String: String] = ["email": email, "password": password]
        guard let data = await post("/auth/login", body: body) else {
            await MainActor.run { isLoading = false }
            return false
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionObj = json["session"] as? [String: Any],
              let accessToken = sessionObj["access_token"] as? String,
              let refreshToken = sessionObj["refresh_token"] as? String,
              let userObj = json["user"] as? [String: Any],
              let userId = userObj["id"] as? String else {
            await MainActor.run {
                self.error = "Unable to sign in. Verify your email and try again."
                isLoading = false
            }
            return false
        }

        let authSession = AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: sessionObj["expires_at"] as? Int,
            userId: userId,
            email: (userObj["email"] as? String) ?? email,
            fullName: (userObj["full_name"] as? String) ?? email.components(separatedBy: "@").first ?? ""
        )

        let established = await establishSession(authSession)
        if established {
            await MainActor.run { lifecycleState = .crossDeviceVerified(authSession.email) }
        }
        return established
    }

    func reopenBrowserSignup(email: String) {
        Task { _ = await signup(email: email, password: "", fullName: "") }
    }

    func returnToSignIn(email: String) {
        self.error = nil
        lifecycleState = .credentials
    }

    // MARK: - Logout

    func logout() {
        let oldUserID = session?.userId
        onSessionWillChange?(oldUserID, nil)
        session = nil
        isAuthenticated = false
        do {
            try sessionStore.delete()
        } catch {
            self.error = "Could not remove credentials from Keychain."
        }
        onSessionDidChange?(nil)
    }

    // MARK: - Token Refresh

    private var isRefreshing = false

    /// Ensures the access token is fresh. Call before making authenticated requests.
    func ensureValidToken() async {
        guard let session, !isRefreshing else { return }

        // Check if token is expired or about to expire (within 60s)
        if let exp = session.expiresAt, Double(exp) > Date().timeIntervalSince1970 + 60 {
            return // Still valid
        }

        print("[AuthManager] Token expired, refreshing...")
        isRefreshing = true
        defer { isRefreshing = false }

        guard let url = URL(string: baseURL + "/auth/refresh") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["refresh_token": session.refreshToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard status == 200,
                  let json,
                  let sessionObj = json["session"] as? [String: Any],
                  let newAccess = sessionObj["access_token"] as? String,
                  let newRefresh = sessionObj["refresh_token"] as? String else {
                let code = json?["code"] as? String
                let disposition = RefreshFailureDisposition.classify(statusCode: status, code: code)
                print("[AuthManager] Refresh failed (status=\(status), disposition=\(disposition))")
                await MainActor.run {
                    if disposition == .logout {
                        self.logout()
                    } else {
                        self.error = "Session refresh is temporarily unavailable. Your saved session was preserved."
                    }
                }
                return
            }

            let updated = AuthSession(
                accessToken: newAccess,
                refreshToken: newRefresh,
                expiresAt: sessionObj["expires_at"] as? Int,
                userId: session.userId,
                email: session.email,
                fullName: session.fullName
            )

            do {
                try sessionStore.rotate(from: session.userId, to: updated)
                await MainActor.run {
                    guard self.session?.userId == session.userId else { return }
                    self.session = updated
                    self.isAuthenticated = true
                    self.onSessionDidChange?(updated)
                }
            } catch {
                await MainActor.run {
                    self.error = "Credential refresh could not be saved. Your existing session was preserved."
                }
            }
            print("[AuthManager] Token refreshed successfully")
        } catch {
            print("[AuthManager] Refresh error: \(error.localizedDescription)")
            await MainActor.run {
                self.error = "Session refresh is temporarily unavailable. Your saved session was preserved."
            }
        }
    }

    // MARK: - Persistence

    private func establishSession(_ newSession: AuthSession) async -> Bool {
        do {
            let previousUserID = await MainActor.run { session?.userId }
            await MainActor.run { onSessionWillChange?(previousUserID, newSession.userId) }
            try sessionStore.save(newSession)
            // Legacy import is allowed only after the matching session is
            // durably present in Keychain.
            try? accountDataStore.migrateLegacyData(
                activeSession: newSession,
                sessionStore: sessionStore
            )
            await MainActor.run {
                session = newSession
                isAuthenticated = true
                isLoading = false
                onSessionDidChange?(newSession)
            }
            return true
        } catch {
            await MainActor.run {
                session = nil
                isAuthenticated = false
                isLoading = false
                self.error = "Could not secure this session in Keychain."
                onSessionDidChange?(nil)
            }
            return false
        }
    }

    private func loadSession() {
        guard let session = try? sessionStore.load() else {
            return
        }
        self.session = session
        self.isAuthenticated = true
        onSessionDidChange?(session)

        // Refresh token on startup if needed
        Task { await ensureValidToken() }
    }

    // MARK: - HTTP

    private func post(_ path: String, body: [String: String]) async -> Data? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            if let httpResponse, httpResponse.statusCode >= 400 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errMsg = json["error"] as? String {
                    await MainActor.run {
                        self.error = errMsg
                        switch json["code"] as? String {
                        case "email_verification_required":
                            self.lifecycleState = .checkEmail("")
                        case "provisioning_retry_required":
                            self.lifecycleState = .repairProvisioning
                        default:
                            break
                        }
                    }
                }
                return nil
            }
            return data
        } catch {
            await MainActor.run { self.error = "Cannot reach server — is the backend running?" }
            return nil
        }
    }
}
