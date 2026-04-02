import Foundation
import Swifter

class WebSocketServer {
    private let server = HttpServer()
    private let viewModel: NotchViewModel
    private var sessions: [ObjectIdentifier: WebSocketSession] = [:]

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        setupRoutes()
    }

    private func setupRoutes() {
        server["/ws"] = websocket(
            text: { [weak self] _, text in
                self?.handleMessage(text)
            },
            connected: { [weak self] session in
                let id = ObjectIdentifier(session)
                self?.sessions[id] = session
                print("[WS] Client connected (\(self?.sessions.count ?? 0) total)")
            },
            disconnected: { [weak self] session in
                let id = ObjectIdentifier(session)
                self?.sessions.removeValue(forKey: id)
                print("[WS] Client disconnected (\(self?.sessions.count ?? 0) total)")
            }
        )

        server["/health"] = { _ in
            .ok(.text("ok"))
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[WS] Received non-object JSON")
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.viewModel.processEvent(json)
            }
        } catch {
            print("[WS] JSON parse error: \(error)")
        }
    }

    func start() {
        do {
            try server.start(7778, forceIPv4: true)
            print("[Danotch] WebSocket server running on ws://localhost:7778/ws")
        } catch {
            print("[Danotch] Failed to start WebSocket server: \(error)")
        }
    }

    func stop() {
        server.stop()
        print("[Danotch] WebSocket server stopped")
    }
}
