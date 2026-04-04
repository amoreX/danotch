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
    private let baseURL = "http://localhost:3001"

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
