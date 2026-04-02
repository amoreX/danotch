import SwiftUI

// MARK: - Nothing-Inspired Design Tokens

enum DN {
    // MARK: Colors (Dark Mode — OLED instrument panel)

    static let black           = Color(hex: 0x000000)
    static let surface         = Color(hex: 0x111111)
    static let surfaceRaised   = Color(hex: 0x1A1A1A)
    static let border          = Color(hex: 0x222222)
    static let borderVisible   = Color(hex: 0x333333)
    static let textDisabled    = Color(hex: 0x666666)
    static let textSecondary   = Color(hex: 0x999999)
    static let textPrimary     = Color(hex: 0xE8E8E8)
    static let textDisplay     = Color.white

    static let accent          = Color(hex: 0xD71921)  // Signal red — one per screen
    static let accentSubtle    = Color(hex: 0xD71921).opacity(0.15)
    static let success         = Color(hex: 0x4A9E5C)
    static let warning         = Color(hex: 0xD4A843)

    // MARK: Typography

    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .light, design: .monospaced)
    }

    static func heading(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func label(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func body(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
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

    // MARK: Motion

    static let microDuration: Double = 0.2
    static let transitionDuration: Double = 0.35

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
        case .failed:           return accent
        case .cancelled:        return textDisabled
        case .pending:          return textDisabled
        }
    }
}

// MARK: - Color hex initializer

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8)  & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
