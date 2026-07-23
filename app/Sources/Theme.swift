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

    static let accent          = Color(hex: 0x8B7CF6)  // Soft purple
    static let accentSubtle    = Color(hex: 0x8B7CF6).opacity(0.15)
    static let success         = Color(hex: 0x4A9E5C)
    static let warning         = Color(hex: 0xD4A843)

    // Dim purple tint for active glass buttons. Deliberately dim so
    // SwiftUI's glass style does NOT auto-invert the foreground to
    // black; the white label stays white against this surface.
    static let activeAccent    = Color(hex: 0x3D3270)

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

    // MARK: Spacing (4px base scale)

    static let space2xs: CGFloat = 2
    static let spaceXS:  CGFloat = 4
    static let spaceSM:  CGFloat = 8
    static let spaceMD:  CGFloat = 12
    static let spaceLG:  CGFloat = 20
    static let spaceXL:  CGFloat = 32

    // MARK: Corner radius scale (single source of truth)

    static let radiusXS: CGFloat = 6   // tiny inline pills
    static let radiusSM: CGFloat = 8   // row hovers, small chips
    static let radiusMD: CGFloat = 12  // cards, inputs
    static let radiusLG: CGFloat = 16  // major panels
    static let radiusXL: CGFloat = 20  // shell-level surfaces

    // MARK: Motion

    static let microDuration: Double = 0.2
    static let transitionDuration: Double = 0.35

    static var microAnimation: Animation {
        .easeOut(duration: microDuration)
    }

    static var transition: Animation {
        .spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.15)
    }

    // Tahoe-style spring animations
    static var expandSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.74, blendDuration: 0.1)
    }

    static var collapseSpring: Animation {
        .spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0.1)
    }

    static var peekSpring: Animation {
        .spring(response: 0.5, dampingFraction: 0.78, blendDuration: 0.15)
    }

    static var viewStateSpring: Animation {
        .spring(response: 0.38, dampingFraction: 0.82, blendDuration: 0.15)
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

// MARK: - Liquid Glass (vanilla Apple primitive)
//
// Per Apple's Liquid Glass guidance (macOS 26+):
//   - glass belongs only on the navigation/controls layer, never on content
//   - never hand-paint sheens, gradient strokes, or borders — the material does that
//   - neighboring glass surfaces must share a GlassEffectContainer
//
extension View {
    @ViewBuilder
    func perchGlass<S: Shape>(
        tint: Color? = nil,
        in shape: S
    ) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                glassEffect(Glass.regular.tint(tint), in: shape)
            } else {
                glassEffect(.regular, in: shape)
            }
        } else {
            background(
                (tint ?? Color.white).opacity(tint == nil ? 0.08 : 0.18),
                in: shape
            )
            .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    func liquidGlass(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil,
        intensity: Double = 1.0,
        elevated: Bool = false
    ) -> some View {
        perchGlass(
            tint: tint?.opacity(0.6),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    func glassCell(cornerRadius: CGFloat = 14) -> some View {
        perchGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Plain content card — flat dark fill, no glass. Per Apple's Liquid Glass
    /// guidance, content layers (lists, cards, chat bubbles) must NOT use glass —
    /// only navigation/controls do. Use this for grouped content sections.
    func contentCard(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Smart edge fade for `ScrollView` — fades the top edge only while the
    /// content is scrolled away from the top, and the bottom edge only while
    /// it's away from the bottom. Snaps off cleanly at either extreme.
    func smartScrollFade(_ length: CGFloat = 24, bottomRadius: CGFloat = 0) -> some View {
        modifier(SmartScrollFade(length: length, bottomRadius: bottomRadius))
    }
}

private struct SmartScrollFade: ViewModifier {
    let length: CGFloat
    let bottomRadius: CGFloat
    @State private var fadeTop: Bool = false
    @State private var fadeBottom: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            tracked(content: content)
        } else {
            content
        }
    }

    @available(macOS 15.0, *)
    private func tracked(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ScrollEdges.self) { geo in
                let off = geo.contentOffset.y
                let inset = geo.contentInsets.top
                let max  = geo.contentSize.height - geo.containerSize.height
                let nearTop    = off <= inset + 1
                let nearBottom = off >= max - 1
                return ScrollEdges(top: !nearTop, bottom: !nearBottom)
            } action: { _, new in
                withAnimation(.easeOut(duration: 0.18)) {
                    fadeTop = new.top
                    fadeBottom = new.bottom
                }
            }
            .mask {
                GeometryReader { proxy in
                    let fade = min(max(length / max(proxy.size.height, 1), 0.02), 0.45)

                    LinearGradient(
                        stops: [
                            .init(color: fadeTop    ? .clear : .black, location: 0.0),
                            .init(color: .black,                       location: fade),
                            .init(color: .black,                       location: 1 - fade),
                            .init(color: fadeBottom ? .clear : .black, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: bottomRadius,
                            bottomTrailingRadius: bottomRadius,
                            topTrailingRadius: 0,
                            style: .continuous
                        )
                    )
                }
            }
    }
}

private struct ScrollEdges: Equatable {
    var top: Bool
    var bottom: Bool
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
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .foregroundStyle(.yellow)
                Text("\(count) active")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
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
