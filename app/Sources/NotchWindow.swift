import AppKit
import Carbon
import Combine
import SwiftUI

class PerchPanel: NSPanel {
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

    // Make AppKit *render* controls as active (so .buttonStyle(.glass) shows
    // its proper key-window appearance) without actually stealing focus from
    // the foreground app. We never call makeKey unless the chat input is
    // being focused; until then the panel is visually key but inactive.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { false }
}

class NotchWindowController: NSObject {
    let viewModel: NotchViewModel
    /// One panel per attached NSScreen, keyed by screen.dn_uuid.
    /// The first panel created hosts the SwiftUI view; secondary panels just
    /// mirror its frame so the UI stays in one place. We swap which panel is
    /// "active" as the cursor moves between monitors.
    private var panels: [String: PerchPanel] = [:]
    /// The panel currently hosting the SwiftUI view + reacting to hover.
    private var activeScreenUUID: String?
    var globalMonitor: Any?
    var localMonitor: Any?
    var scrollMonitor: Any?
    var keyboardMonitor: Any?
    var localKeyboardMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    var collapseTimer: Timer?
    var swipeAccumulator: CGFloat = 0
    private var peekCancellable: AnyCancellable?

    // The panel is sized well beyond the visible notch/expanded shape (which
    // maxes out around 540x360) so SwiftUI-drawn effects that extend past the
    // shape's edges — the drop shadow, and the widget-drag grab area near
    // the grid's boundary — always have room to render/track without being
    // clipped by the window frame. It intentionally does NOT span the full
    // screen: `ignoresMouseEvents` is what makes clicks pass through to
    // other apps outside the notch, and that only works reliably because the
    // window itself doesn't cover those areas in the first place.
    private let panelWidth: CGFloat = 740
    private let panelHeight: CGFloat = 500

    private var activePanel: PerchPanel? {
        if let uuid = activeScreenUUID { return panels[uuid] }
        return nil
    }

    init(viewModel: NotchViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func show() {
        rebuildPanels()
        startMouseTracking()
        startKeyboardShortcut()
        startPeekPresentation()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor); scrollMonitor = nil }
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor); keyboardMonitor = nil }
        if let monitor = localKeyboardMonitor { NSEvent.removeMonitor(monitor); localKeyboardMonitor = nil }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let hotKeyHandlerRef { RemoveEventHandler(hotKeyHandlerRef); self.hotKeyHandlerRef = nil }
        collapseTimer?.invalidate()
        collapseTimer = nil
        peekCancellable?.cancel()
        peekCancellable = nil
        panels.values.forEach { $0.orderOut(nil) }
        panels.removeAll()
        activeScreenUUID = nil
    }

    /// Tear down existing panels and create a fresh one for every attached
    /// screen. We do this on initial show and whenever the screen layout
    /// changes (monitor plug/unplug, resolution change).
    private func rebuildPanels() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
        activeScreenUUID = nil

        let styleMask: NSWindow.StyleMask = [
            .borderless, .nonactivatingPanel, .utilityWindow, .hudWindow,
        ]

        for screen in NSScreen.screens {
            let panel = PerchPanel(
                contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            panel.ignoresMouseEvents = true
            panel.acceptsMouseMovedEvents = true
            positionPanel(panel, on: screen)
            panel.orderFrontRegardless()
            panels[screen.dn_uuid] = panel
        }

        // Pick whichever screen currently has the mouse, falling back to the
        // main screen, then to any screen.
        let target = screenForMouse() ?? NSScreen.main ?? NSScreen.screens.first
        if let target = target {
            activateScreen(target)
        }
    }

    /// Move the SwiftUI host into the panel on `screen` and update tracking
    /// so that monitor becomes the interactive one.
    private func activateScreen(_ screen: NSScreen) {
        let uuid = screen.dn_uuid
        guard let panel = panels[uuid] else { return }
        if activeScreenUUID == uuid && panel.contentView is NSHostingView<NotchShellView> {
            return
        }

        // Strip the SwiftUI host from the previously active panel, if any.
        if let prevUUID = activeScreenUUID, prevUUID != uuid, let prev = panels[prevUUID] {
            prev.contentView = nil
            prev.ignoresMouseEvents = true
        }

        let shellView = NotchShellView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: shellView)
        // Disable automatic window resizing — the panel frame is managed
        // entirely by NotchWindowController. Without this, NSHostingView
        // calls updateAnimatedWindowSize during layout causing re-entrant
        // constraint updates and an EXC_BREAKPOINT crash on macOS 26.
        hosting.sizingOptions = []
        // Ensure the hosting view's own CALayer is fully transparent so
        // NSVisualEffectView / glassEffect can composite against the desktop.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        activeScreenUUID = uuid
    }

    private func positionPanel(_ panel: PerchPanel, on screen: NSScreen) {
        let w = panel.frame.width
        let h = panel.frame.height
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.origin.x + (screen.frame.width / 2) - w / 2,
            y: screen.frame.origin.y + screen.frame.height - h
        ))
    }

    @objc private func screenChanged() {
        rebuildPanels()
    }

    /// Return the NSScreen currently under the cursor (in global coords).
    private func screenForMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    // MARK: - Global Keyboard Shortcut (Cmd+Shift+Space)

    private func startKeyboardShortcut() {
        registerSystemHotKey()

        // Escape remains a local shortcut while the panel has focus. The
        // Command-Shift-Space hotkey is handled by Carbon both locally and
        // globally, avoiding Input Monitoring/Accessibility requirements.
        localKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && self?.viewModel.isExpanded == true {
                self?.collapse()
                return nil
            }
            return event
        }
    }

    private func registerSystemHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                      hotKeyID.signature == 0x50524348,
                      hotKeyID.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let controller = Unmanaged<NotchWindowController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    controller.handleGlobalShortcut()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandlerRef
        )
        guard handlerStatus == noErr else {
            print("[Perch] Could not install global hotkey handler: \(handlerStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x50524348, id: 1) // "PRCH"
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registrationStatus != noErr {
            print("[Perch] Could not register Command-Shift-Space: \(registrationStatus)")
            if let hotKeyHandlerRef {
                RemoveEventHandler(hotKeyHandlerRef)
                self.hotKeyHandlerRef = nil
            }
        }
    }

    private var shortcutCollapsedAt: Date = .distantPast

    private func handleGlobalShortcut() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.viewModel.isExpanded {
                self.shortcutCollapsedAt = Date()
                self.collapse()
            } else {
                // Drop down on whichever monitor currently has the cursor in
                // quick-prompt mode — a semi-expanded notch with just a glass
                // text field. Sending will spring the panel to full height
                // and continue in the chat view.
                if let screen = self.screenForMouse() {
                    self.activateScreen(screen)
                }
                self.viewModel.isQuickPrompt = true
                self.expand()
                self.viewModel.viewState = .overview
                self.viewModel.shouldFocusChatInput = true
                self.activePanel?.makeKeyAndOrderFront(nil)
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

    private func startPeekPresentation() {
        peekCancellable = viewModel.$isPeeking
            .removeDuplicates()
            .sink { [weak self] isPeeking in
                guard let self else { return }
                if isPeeking {
                    self.presentPeek()
                } else if !self.viewModel.isExpanded {
                    self.activePanel?.ignoresMouseEvents = true
                    self.activePanel?.resignKey()
                }
            }
    }

    private func presentPeek() {
        collapseTimer?.invalidate()
        collapseTimer = nil

        if let screen = screenForMouse() ?? NSScreen.main {
            activateScreen(screen)
        }

        activePanel?.ignoresMouseEvents = false
        activePanel?.hasShadow = false
        activePanel?.orderFrontRegardless()
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
            withAnimation(DN.viewStateSpring) {
                viewModel.viewState = .overview
            }
        }
    }

    /// The rect (in global screen coordinates) that should actually receive
    /// mouse events right now — the physical notch when collapsed, or the
    /// expanded shape when expanded/peeking. Drives hover-triggered
    /// expand/collapse.
    ///
    /// Discrete trigger zones — no fuzzy in-between region:
    ///  - Collapsed: only the physical notch rect (exact width, exact height)
    ///  - Expanded: only the actual expanded shape rect
    ///  No padding, no overshoot — state flips cleanly between off and on.
    private func currentInteractiveRect(on screen: NSScreen) -> NSRect {
        let cx = screen.frame.midX
        let nw = screen.notchWidth
        let nh = screen.notchHeight

        if viewModel.isExpanded {
            let ew = expandedShapeWidth(notchW: nw)
            let eh = expandedShapeHeight(notchH: nh)
            return NSRect(x: cx - ew / 2, y: screen.frame.maxY - eh, width: ew, height: eh)
        }

        // Extend the hit rect UP past the screen's top edge so the very
        // topmost row of pixels (which macOS sometimes reserves for the
        // menu-bar edge / system gestures and which NSRect.contains
        // treats as exclusive on the max edge) still counts as a hit.
        let edgeSlack: CGFloat = 4
        return NSRect(x: cx - nw / 2, y: screen.frame.maxY - nh, width: nw, height: nh + edgeSlack)
    }

    private func checkMouse() {
        // Mouse position is in global coordinates, which span every attached
        // display, so we resolve which screen the cursor is on each tick.
        guard let screen = screenForMouse() else { return }
        let mouse = NSEvent.mouseLocation
        let hit = currentInteractiveRect(on: screen).contains(mouse)

        if hit {
            // The cursor is now on `screen`; make sure the SwiftUI host lives
            // there so this monitor's panel is the interactive one.
            if activeScreenUUID != screen.dn_uuid {
                activateScreen(screen)
            }
            collapseTimer?.invalidate()
            collapseTimer = nil
            if !viewModel.isExpanded && Date().timeIntervalSince(shortcutCollapsedAt) > 0.6 {
                expand()
            }
        } else if viewModel.isExpanded {
            // Don't touch anything while a widget drag is in flight — the
            // cursor can legitimately stray past the shape's hit-test rect
            // mid-drag (e.g. near the grid edges) and we must not blur/collapse.
            if viewModel.isDraggingWidget {
                return
            }
            // Clear chat input focus when mouse leaves the panel entirely
            if viewModel.isChatInputActive {
                viewModel.isChatInputActive = false
                viewModel.shouldFocusChatInput = false
            }
            // Settings stays open so controls remain usable. Chats respect the
            // user's keep-open preference; all other pages auto-collapse.
            if shouldKeepCurrentViewOpen {
                return
            }
            // Don't auto-collapse while an app connection is in progress
            if viewModel.appLoading.values.contains(true) {
                return
            }
            scheduleCollapse()
        }
    }

    // Single canonical expanded size — must match NotchShellView.expandedW/H
    private func expandedShapeWidth(notchW: CGFloat) -> CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchW + 200 : notchW + 140
        }
        return NotchShellView.expandedW
    }

    private func expandedShapeHeight(notchH: CGFloat) -> CGFloat {
        if viewModel.isPeeking {
            return viewModel.peekHovering ? notchH + 80 : notchH + 28
        }
        if viewModel.isQuickPrompt {
            return notchH + NotchShellView.quickPromptH
        }
        if viewModel.viewState == .overview {
            return notchH + viewModel.settings.todayExpandedH
        }
        return notchH + NotchShellView.expandedH
    }

    private func expand() {
        activePanel?.ignoresMouseEvents = false
        // Keep window shadow off — AppKit renders it above the screen edge
        // as a hairline at the top of the notch shape. The drop shadow is
        // drawn inside SwiftUI instead, where we can clip it to the bottom.
        activePanel?.hasShadow = false
        viewModel.restoreOrResetView()
        // .nonactivatingPanel + makeKeyAndOrderFront makes the panel key —
        // so SwiftUI/AppKit renders controls in their proper active state —
        // WITHOUT activating the app. The foreground app stays main and
        // keeps its own focus, but our glass buttons no longer look flat.
        activePanel?.makeKeyAndOrderFront(nil)
        withAnimation(DN.expandSpring) {
            viewModel.isExpanded = true
        }
    }

    private func collapse() {
        withAnimation(DN.collapseSpring) {
            viewModel.isExpanded = false
            viewModel.isQuickPrompt = false
            viewModel.isChatInputActive = false
            viewModel.resetView()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            if !self.viewModel.isExpanded {
                self.activePanel?.ignoresMouseEvents = true
                self.activePanel?.resignKey()
            }
        }
    }

    private func scheduleCollapse() {
        guard collapseTimer == nil else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.collapseTimer = nil
            guard !self.shouldKeepCurrentViewOpen,
                  !self.viewModel.isChatInputActive,
                  !self.viewModel.isDraggingWidget,
                  !self.viewModel.appLoading.values.contains(true) else { return }

            // `mouseInContent` is reported by the full transparent hosting
            // view, which is intentionally larger than the visible notch.
            // Re-check the actual shape instead so invisible margins cannot
            // keep Today, Agents, Stats, or Notifications open forever.
            let mouse = NSEvent.mouseLocation
            let isInsideVisibleShape = self.screenForMouse().map {
                self.currentInteractiveRect(on: $0).contains(mouse)
            } ?? false
            if !isInsideVisibleShape {
                self.collapse()
            }
        }
    }

    private var shouldKeepCurrentViewOpen: Bool {
        switch viewModel.viewState {
        case .settings:
            return true
        case .agentChat:
            return viewModel.settings.keepOpenInChat
        default:
            return false
        }
    }

    deinit {
        close()
    }
}

extension NSScreen {
    /// Stable per-display identifier. Falls back to the address of the
    /// NSScreen if the device description is missing.
    var dn_uuid: String {
        if let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "display-\(n.uint32Value)"
        }
        return "screen-\(ObjectIdentifier(self).hashValue)"
    }

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
