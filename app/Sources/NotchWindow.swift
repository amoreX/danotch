import AppKit
import SwiftUI

class DanotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }

    // Must be true for TextField to receive keyboard input
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class NotchWindowController: NSObject {
    var panel: DanotchPanel!
    let viewModel: NotchViewModel
    var globalMonitor: Any?
    var localMonitor: Any?
    var scrollMonitor: Any?
    var keyboardMonitor: Any?
    var localKeyboardMonitor: Any?
    var collapseTimer: Timer?
    var swipeAccumulator: CGFloat = 0

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func show() {
        guard let screen = NSScreen.main else {
            print("[Danotch] No main screen found")
            return
        }

        let panelWidth: CGFloat = 580
        let panelHeight: CGFloat = 400
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]

        let panel = DanotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let shellView = NotchShellView(viewModel: viewModel)
        panel.contentView = NSHostingView(rootView: shellView)

        self.panel = panel
        positionPanel(on: screen)
        panel.orderFrontRegardless()

        startMouseTracking()
        startKeyboardShortcut()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func positionPanel(on screen: NSScreen) {
        let w = panel.frame.width
        let h = panel.frame.height
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.origin.x + (screen.frame.width / 2) - w / 2,
            y: screen.frame.origin.y + screen.frame.height - h
        ))
    }

    @objc private func screenChanged() {
        guard let screen = NSScreen.main else { return }
        positionPanel(on: screen)
    }

    // MARK: - Global Keyboard Shortcut (Cmd+Shift+Space)

    private func startKeyboardShortcut() {
        // Global monitor: fires when app is NOT key
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 49 {
                self?.handleGlobalShortcut()
            }
        }
        // Local monitor: fires when app IS key (panel has focus)
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 49 {
                self?.handleGlobalShortcut()
                return nil // consume the event
            }
            // Escape to collapse
            if event.keyCode == 53 && self?.viewModel.isExpanded == true {
                self?.collapse()
                return nil
            }
            return event
        }
    }

    private func handleGlobalShortcut() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.viewModel.isExpanded {
                self.collapse()
            } else {
                self.expand()
                self.viewModel.viewState = .overview
                self.viewModel.shouldFocusChatInput = true
                // Make panel key so TextField can receive input
                self.panel.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    // MARK: - Global Mouse Tracking

    private func startMouseTracking() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkMouse()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkMouse()
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }
    }

    private func handleScroll(_ event: NSEvent) {
        guard viewModel.isExpanded else { return }
        guard viewModel.viewState == .taskList else { return }

        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2 else { return }

        guard event.phase == .changed || event.momentumPhase == .changed else {
            if event.phase == .ended || event.phase == .cancelled {
                swipeAccumulator = 0
            }
            return
        }

        swipeAccumulator += event.scrollingDeltaX

        if swipeAccumulator > 60 {
            swipeAccumulator = 0
            withAnimation(.snappy(duration: 0.35)) {
                viewModel.viewState = .overview
            }
        }
    }

    private func checkMouse() {
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation

        let cx = screen.frame.midX
        let nw = screen.notchWidth
        let nh = screen.notchHeight

        let triggerZone = NSRect(
            x: cx - (nw + 60) / 2,
            y: screen.frame.maxY - nh - 10,
            width: nw + 60,
            height: nh + 10
        )

        let inTrigger = triggerZone.contains(mouse)
        let inContent = viewModel.mouseInContent

        if inTrigger || inContent {
            collapseTimer?.invalidate()
            collapseTimer = nil
            if !viewModel.isExpanded && viewModel.settings.expandOnHover {
                expand()
            }
        } else if viewModel.isExpanded {
            // Clear chat input focus when mouse leaves the panel entirely
            if viewModel.isChatInputActive {
                viewModel.isChatInputActive = false
                viewModel.shouldFocusChatInput = false
            }
            scheduleCollapse()
        }
    }

    private func expand() {
        panel.ignoresMouseEvents = false
        withAnimation(.snappy(duration: 0.35)) {
            viewModel.isExpanded = true
        }
    }

    private func collapse() {
        withAnimation(.snappy(duration: 0.3)) {
            viewModel.isExpanded = false
            viewModel.isChatInputActive = false
            viewModel.resetView()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            if !self.viewModel.isExpanded {
                self.panel.ignoresMouseEvents = true
                self.panel.resignKey()
            }
        }
    }

    private func scheduleCollapse() {
        guard collapseTimer == nil else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.collapseTimer = nil
            if !self.viewModel.mouseInContent && !self.viewModel.isChatInputActive {
                self.collapse()
            }
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = keyboardMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyboardMonitor { NSEvent.removeMonitor(m) }
        collapseTimer?.invalidate()
    }
}

extension NSScreen {
    var hasNotch: Bool {
        safeAreaInsets.top > 0
    }

    var notchHeight: CGFloat {
        let menuBarHeight = frame.maxY - visibleFrame.maxY
        return max(menuBarHeight, 32)
    }

    var notchWidth: CGFloat {
        guard hasNotch else { return 180 }
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea {
            return right.minX - left.maxX
        }
        return 200
    }
}
