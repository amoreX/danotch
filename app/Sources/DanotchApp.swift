import SwiftUI
import AppKit
import CoreText

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
        registerFonts()

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

    private func registerFonts() {
        let fontNames = [
            "Satoshi-Light", "Satoshi-LightItalic",
            "Satoshi-Regular", "Satoshi-Italic",
            "Satoshi-Medium", "Satoshi-MediumItalic",
            "Satoshi-Bold", "Satoshi-BoldItalic",
            "Satoshi-Black", "Satoshi-BlackItalic",
        ]
        for name in fontNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "otf",
                                              subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
