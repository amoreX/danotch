import SwiftUI
import AppKit

struct DotGridView: View {
    var dotColor: Color = .white
    let spacing: CGFloat = 14
    let baseDotSize: CGFloat = 1.2
    let influenceRadius: CGFloat = 80

    @StateObject private var tracker = MouseTracker()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let cols = Int(size.width / spacing) + 1
                    let rows = Int(size.height / spacing) + 1

                    let offsetX = (size.width - CGFloat(cols - 1) * spacing) / 2
                    let offsetY = (size.height - CGFloat(rows - 1) * spacing) / 2

                    // Convert global mouse to local coordinates
                    let localMouse = tracker.localPosition(in: geo)

                    for row in 0..<rows {
                        for col in 0..<cols {
                            let x = offsetX + CGFloat(col) * spacing
                            let y = offsetY + CGFloat(row) * spacing

                            // Distance from mouse
                            let dx = x - localMouse.x
                            let dy = y - localMouse.y
                            let dist = sqrt(dx * dx + dy * dy)

                            // Ambient wave
                            let wave = sin(time * 0.8 + Double(col) * 0.3 + Double(row) * 0.2) * 0.18 + 0.18

                            // Mouse influence
                            var mouseInfluence: Double = 0
                            var pushX: CGFloat = 0
                            var pushY: CGFloat = 0

                            if dist < influenceRadius {
                                let t = 1.0 - (dist / influenceRadius)
                                let eased = t * t
                                mouseInfluence = eased

                                let angle = atan2(dy, dx)
                                let pushDist = eased * 4
                                pushX = cos(angle) * pushDist
                                pushY = sin(angle) * pushDist
                            }

                            let opacity = min(0.15 + wave + mouseInfluence * 0.7, 1.0)
                            let dotSize = baseDotSize + CGFloat(mouseInfluence) * 2.5

                            let rect = CGRect(
                                x: x + pushX - dotSize / 2,
                                y: y + pushY - dotSize / 2,
                                width: dotSize,
                                height: dotSize
                            )

                            context.fill(
                                Circle().path(in: rect),
                                with: .color(dotColor.opacity(opacity))
                            )
                        }
                    }
                }
            }
        }
    }
}

// Tracks global mouse position without needing hit testing
private class MouseTracker: ObservableObject {
    @Published var globalPosition: CGPoint = .zero
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.globalPosition = NSEvent.mouseLocation
            return event
        }
        // Also pick up moves when app isn't focused
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.globalPosition = NSEvent.mouseLocation
        }
    }

    func localPosition(in geo: GeometryProxy) -> CGPoint {
        // Convert screen coordinates to view-local
        let frame = geo.frame(in: .global)
        // NSEvent.mouseLocation is bottom-left origin, SwiftUI is top-left
        // geo.frame(in: .global) is in window coordinates (top-left origin)
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            return .zero
        }
        let windowFrame = window.frame
        let screenMouse = globalPosition

        // Screen to window
        let windowX = screenMouse.x - windowFrame.origin.x
        let windowY = windowFrame.height - (screenMouse.y - windowFrame.origin.y)

        // Window to local view
        let localX = windowX - frame.origin.x
        let localY = windowY - frame.origin.y

        return CGPoint(x: localX, y: localY)
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
