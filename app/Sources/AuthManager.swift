import Foundation
import SwiftUI

struct AuthSession: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Int?
    var userId: String
    var email: String
    var fullName: String
}

class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var session: AuthSession?
    @Published var isAuthenticated = false
    @Published var isLoading = false
    @Published var error: String?

    private static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".danotch")
    private static let authFile = configDir.appendingPathComponent("auth.json")
    private var baseURL: String { APIConfig.baseURL }

    var userName: String {
        session?.fullName ?? session?.email.components(separatedBy: "@").first ?? ""
    }

    var accessToken: String? { session?.accessToken }

    init() {
        loadSession()
    }

    // MARK: - Signup

    func signup(email: String, password: String, fullName: String) async -> Bool {
        await MainActor.run { isLoading = true; error = nil }

        let body: [String: String] = ["email": email, "password": password, "full_name": fullName]
        guard let data = await post("/auth/signup", body: body) else {
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
                self.error = "Signup failed"
                isLoading = false
            }
            return false
        }

        let email = (userObj["email"] as? String) ?? email
        let name = (userObj["full_name"] as? String) ?? fullName

        let authSession = AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: sessionObj["expires_at"] as? Int,
            userId: userId,
            email: email,
            fullName: name
        )

        await MainActor.run {
            self.session = authSession
            self.isAuthenticated = true
            self.isLoading = false
        }
        saveSession(authSession)
        return true
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
                self.error = "Login failed"
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

        await MainActor.run {
            self.session = authSession
            self.isAuthenticated = true
            self.isLoading = false
        }
        saveSession(authSession)
        return true
    }

    // MARK: - Logout

    func logout() {
        session = nil
        isAuthenticated = false
        try? FileManager.default.removeItem(at: Self.authFile)
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

            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionObj = json["session"] as? [String: Any],
                  let newAccess = sessionObj["access_token"] as? String,
                  let newRefresh = sessionObj["refresh_token"] as? String else {
                print("[AuthManager] Refresh failed (status=\(status)), logging out")
                await MainActor.run { self.logout() }
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

            await MainActor.run {
                self.session = updated
                self.isAuthenticated = true
            }
            saveSession(updated)
            print("[AuthManager] Token refreshed successfully")
        } catch {
            print("[AuthManager] Refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence

    private func saveSession(_ session: AuthSession) {
        do {
            try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(session)
            try data.write(to: Self.authFile)
        } catch {
            print("[AuthManager] Failed to save session: \(error)")
        }
    }

    private func loadSession() {
        guard let data = try? Data(contentsOf: Self.authFile),
              let session = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            return
        }
        self.session = session
        self.isAuthenticated = true

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
                    await MainActor.run { self.error = errMsg }
                }
                return nil
            }
            return data
        } catch {
            await MainActor.run { self.error = "Cannot reach server" }
            return nil
        }
    }
}
