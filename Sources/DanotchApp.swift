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
    var wsServer: WebSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        windowController = NotchWindowController(viewModel: viewModel)
        windowController?.show()

        wsServer = WebSocketServer(viewModel: viewModel)
        wsServer?.start()

        print("[Danotch] Ready — hover over the notch to expand")
    }

    func applicationWillTerminate(_ notification: Notification) {
        wsServer?.stop()
    }
}
