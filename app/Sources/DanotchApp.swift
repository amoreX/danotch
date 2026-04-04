import SwiftUI
import AppKit

@main
struct DanotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: NotchWindowController?
    var onboardingWindow: NSWindow?
    let viewModel = NotchViewModel()
    let auth = AuthManager.shared
    var wsServer: WebSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        wsServer = WebSocketServer(viewModel: viewModel)
        wsServer?.start()

        if auth.isAuthenticated {
            // Already logged in — go straight to notch
            viewModel.authManager = auth
            startNotch()
        } else {
            // First launch or logged out — show onboarding
            showOnboarding()
        }
    }

    private func startNotch() {
        onboardingWindow?.close()
        onboardingWindow = nil

        windowController = NotchWindowController(viewModel: viewModel)
        windowController?.show()

        // Go back to accessory mode (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        print("[Danotch] Ready — hover over the notch to expand")
    }

    private func showOnboarding() {
        // Temporarily show in dock so the window gets focus
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.center()

        let onboardingView = OnboardingView(auth: auth) { [weak self] in
            guard let self else { return }
            self.viewModel.authManager = self.auth
            self.startNotch()
        }

        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        wsServer?.stop()
    }
}
