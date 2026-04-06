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
    let viewModel = NotchViewModel()
    let auth = AuthManager.shared
    var wsServer: WebSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Terminate any existing Danotch instances before starting
        let myPID = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        for app in running where app.processIdentifier != myPID {
            app.terminate()
        }

        NSApp.setActivationPolicy(.accessory)

        wsServer = WebSocketServer(viewModel: viewModel)
        wsServer?.start()

        viewModel.authManager = auth
        startNotch()
    }

    private func startNotch() {
        windowController = NotchWindowController(viewModel: viewModel)
        windowController?.show()
        NSApp.setActivationPolicy(.accessory)
        print("[Danotch] Ready — hover over the notch to expand")
    }

    func applicationWillTerminate(_ notification: Notification) {
        wsServer?.stop()
    }
}
