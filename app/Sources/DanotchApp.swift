import SwiftUI
import AppKit
import QuartzCore

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var updates = UpdateController.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updates.checkForUpdates()
                }
                .disabled(!updates.canCheckForUpdates)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: NotchWindowController?
    var onboardingWindow: NSWindow?
    let viewModel = NotchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppIcon()
        viewModel.activateLocalInstallation()
        viewModel.interruptInProgressConversations()

        if OnboardingCompletionStore.isComplete {
            startNotch()
        } else {
            showOnboarding()
        }
    }

    private func applyAppIcon() {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            candidates.append(bundled)
        }
        // Dev (`swift run`): resolve relative to this source file → app/Resources/AppIcon.icns
        let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(sourceDir.appendingPathComponent("Resources/AppIcon.icns"))
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AppIcon.icns"))

        guard let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    private var expandOnFirstLaunch = false

    private func startNotch() {
        let shouldExpand = expandOnFirstLaunch
        expandOnFirstLaunch = false

        onboardingWindow?.close()
        onboardingWindow = nil

        stopNotch()
        windowController = NotchWindowController(viewModel: viewModel)
        windowController?.show()

        // Load initial data
        viewModel.loadThreadHistory()
        viewModel.loadProviderConfigs()
        viewModel.loadProviderModels()
        viewModel.loadUnreadCount()

        // Go back to accessory mode (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        print("[Perch] Ready — hover over the notch to expand")

        if shouldExpand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(DN.expandSpring) {
                    self.viewModel.isExpanded = true
                }
            }
        }
    }

    private func showOnboarding() {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Temporarily show in dock so the window gets focus
        NSApp.setActivationPolicy(.regular)
        applyAppIcon()

        let onboardingSize = NSSize(width: 360, height: 360)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: onboardingSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(onboardingSize)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.center()

        let onboardingView = OnboardingView(
            viewModel: viewModel,
            onWindowSizeChange: { [weak window] size in
                guard let window else { return }
                let newSize = NSSize(width: size.width, height: size.height)
                var frame = window.frame
                let center = NSPoint(x: frame.midX, y: frame.midY)
                frame.size = newSize
                frame.origin = NSPoint(x: center.x - newSize.width / 2, y: center.y - newSize.height / 2)

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.36
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                }
            }
        ) { [weak self] in
            guard let self else { return }
            self.expandOnFirstLaunch = true
            self.startNotch()
        }

        window.contentView = NSHostingView(rootView: onboardingView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }

    private func stopNotch() {
        guard windowController != nil else { return }
        windowController?.close()
        windowController = nil
        viewModel.cancelDaemonConnection()
        viewModel.isExpanded = false
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.interruptInProgressConversations()
        viewModel.cancelDaemonConnection()
    }
}
