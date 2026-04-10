import SwiftUI

// MARK: - Terminal Pro Design Tokens (Option A)

enum DN {
    // MARK: Colors — warmer OLED black, electric green-teal accent

    static let black           = Color(hex: 0x000000)   // pure OLED black — blends with physical notch
    static let surface         = Color(hex: 0x101010)   // elevated surface
    static let surfaceRaised   = Color(hex: 0x161616)   // further raised
    static let border          = Color(hex: 0x1E1E1E)   // subtle border
    static let borderVisible   = Color(hex: 0x2A2A2A)   // visible border
    static let textDisabled    = Color(hex: 0x555555)   // dimmed
    static let textSecondary   = Color(hex: 0x999999)   // secondary
    static let textPrimary     = Color(hex: 0xDDDDDD)   // readable
    static let textDisplay     = Color(hex: 0xF8F8F8)   // near-white

    static let accent          = Color(hex: 0x00E5A0)   // electric green-teal — one per screen
    static let accentSubtle    = Color(hex: 0x00E5A0).opacity(0.12)
    static let success         = Color(hex: 0x00E5A0)   // unified with accent
    static let warning         = Color(hex: 0xD4A843)   // amber — agent running
    static let error           = Color(hex: 0xE05252)   // red — errors only

    // MARK: Typography — Satoshi

    static func display(_ size: CGFloat) -> Font {
        .custom("Satoshi-Light", size: size)
    }

    static func heading(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Satoshi-Bold"
        case .semibold, .medium:    name = "Satoshi-Medium"
        case .light, .thin:         name = "Satoshi-Light"
        default:                    name = "Satoshi-Regular"
        }
        return .custom(name, size: size)
    }

    static func label(_ size: CGFloat = 10) -> Font {
        .custom("Satoshi-Medium", size: size)
    }

    static func body(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "Satoshi-Bold"
        case .semibold, .medium:    name = "Satoshi-Medium"
        case .light, .thin:         name = "Satoshi-Light"
        default:                    name = "Satoshi-Regular"
        }
        return .custom(name, size: size)
    }

    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Spacing (8px base)

    static let space2xs: CGFloat = 2
    static let spaceXS:  CGFloat = 4
    static let spaceSM:  CGFloat = 8
    static let spaceMD:  CGFloat = 16
    static let spaceLG:  CGFloat = 24
    static let spaceXL:  CGFloat = 32

    // MARK: Motion — easeOut only, crisp and fast

    static let microDuration:      Double = 0.15
    static let transitionDuration: Double = 0.28

    static var microAnimation: Animation {
        .easeOut(duration: microDuration)
    }

    static var transition: Animation {
        .easeOut(duration: transitionDuration)
    }

    // MARK: Status color for tasks

    static func statusColor(_ status: TaskStatus) -> Color {
        switch status {
        case .running:          return warning
        case .completed:        return success
        case .awaitingApproval: return accent
        case .failed:           return error
        case .cancelled:        return textDisabled
        case .pending:          return textDisabled
        }
    }
}

// MARK: - Cursor helper

extension View {
    func handCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Shared Date Helpers

/// Parse an ISO8601 date string (with or without fractional seconds) and return a relative date string.
func formatRelativeDate(_ iso: String, fallbackFormat: String = "MMM d") -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: iso) ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }()
    guard let d = date else { return iso }
    return relativeTimeString(d, fallbackFormat: fallbackFormat)
}

func relativeTimeString(_ date: Date, fallbackFormat: String = "MMM d") -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    let days = Int(interval / 86400)
    if days == 1 { return "yesterday" }
    if days < 7 { return "\(days)d ago" }
    let df = DateFormatter()
    df.dateFormat = fallbackFormat
    return df.string(from: date)
}

// MARK: - Color hex initializer

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    init(hexStr: String) {
        let scanner = Scanner(string: hexStr)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Grain Overlay

struct GrainOverlay: View {
    var opacity: Double = 0.45

    var body: some View {
        Canvas { context, size in
            for _ in 0..<Int(size.width * size.height * 0.06) {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let brightness = CGFloat.random(in: 0...1)
                context.fill(
                    Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                    with: .color(Color(white: brightness))
                )
            }
        }
        .blendMode(.overlay)
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}
