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

    // Agent brand colors
    static let claudeOrange    = Color(hex: 0xD97757)

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

// MARK: - Glass Cell Modifier

private struct GlassCell: ViewModifier {
    var cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(DN.surface.opacity(0.55))
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.04), Color.white.opacity(0.01)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.1), Color.white.opacity(0.03)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func glassCell(cornerRadius: CGFloat = 10) -> some View {
        modifier(GlassCell(cornerRadius: cornerRadius))
    }
}

// MARK: - Set Toggle Helper

extension Set {
    mutating func toggle(_ member: Element) {
        if contains(member) {
            remove(member)
        } else {
            insert(member)
        }
    }
}

// MARK: - Active Badge View

struct ActiveBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            HStack(spacing: 3) {
                Circle().fill(DN.warning).frame(width: 4, height: 4)
                Text("\(count) ACTIVE")
                    .font(DN.label(7))
                    .tracking(0.6)
                    .foregroundColor(DN.warning)
            }
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
