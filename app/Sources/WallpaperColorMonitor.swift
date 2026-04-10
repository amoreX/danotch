import AppKit
import SwiftUI
import Combine

// MARK: - Extracted Palette

struct WallpaperPalette: Equatable {
    /// Darkest dominant color — used as gradient base
    let dark: Color
    /// Mid dominant color
    let mid: Color
    /// Accent / brightest extracted color — used for glow
    let accent: Color
    /// Raw NSColor accent for blending (used as Equatable key)
    let accentNS: NSColor

    static func == (lhs: WallpaperPalette, rhs: WallpaperPalette) -> Bool {
        lhs.accentNS.isEqual(rhs.accentNS)
    }

    static let fallback = WallpaperPalette(
        dark:     Color(red: 0.031, green: 0.055, blue: 0.102),
        mid:      Color(red: 0.075, green: 0.063, blue: 0.188),
        accent:   Color(red: 0.52,  green: 0.42,  blue: 0.92),
        accentNS: NSColor(red: 0.52, green: 0.42, blue: 0.92, alpha: 1)
    )
}

// MARK: - Monitor

final class WallpaperColorMonitor: ObservableObject {
    @Published var palette: WallpaperPalette = .fallback

    private var observer: Any?

    init() {
        refresh()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let palette = Self.extract()
            DispatchQueue.main.async { self?.palette = palette }
        }
    }

    // MARK: - Extraction

    private static func extract() -> WallpaperPalette {
        guard
            let screen = NSScreen.main,
            let url = NSWorkspace.shared.desktopImageURL(for: screen),
            let nsImage = NSImage(contentsOf: url),
            let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return .fallback }

        let colors = sampleColors(from: cgImage)
        guard colors.count >= 3 else { return .fallback }

        // Sort by perceived brightness
        let sorted = colors.sorted { brightness($0) < brightness($1) }

        let dark   = sorted[0]
        let mid    = sorted[sorted.count / 2]
        let accent = sorted[sorted.count - 1]

        // Desaturate dark/mid slightly so they read as background tones
        let darkMuted   = muted(dark,   saturationScale: 0.7, brightnessScale: 0.5)
        let midMuted    = muted(mid,    saturationScale: 0.75, brightnessScale: 0.65)
        let accentBoosted = boosted(accent)

        return WallpaperPalette(
            dark:     Color(nsColor: darkMuted),
            mid:      Color(nsColor: midMuted),
            accent:   Color(nsColor: accentBoosted),
            accentNS: accentBoosted
        )
    }

    // Sample a grid of pixels from the image (resized to thumbnail for speed)
    private static func sampleColors(from cgImage: CGImage, gridSize: Int = 16) -> [NSColor] {
        let side = gridSize
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return [] }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        guard let data = ctx.data else { return [] }
        let ptr = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var clusters: [NSColor] = []
        for i in 0..<(side * side) {
            let r = CGFloat(ptr[i * 4])     / 255
            let g = CGFloat(ptr[i * 4 + 1]) / 255
            let b = CGFloat(ptr[i * 4 + 2]) / 255
            clusters.append(NSColor(red: r, green: g, blue: b, alpha: 1))
        }
        return clusters
    }

    // MARK: - Color helpers

    private static func brightness(_ c: NSColor) -> CGFloat {
        guard let rgb = c.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }

    private static func muted(_ c: NSColor, saturationScale: CGFloat, brightnessScale: CGFloat) -> NSColor {
        guard let hsb = c.usingColorSpace(.deviceRGB) else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h,
                       saturation: min(s * saturationScale, 1),
                       brightness: min(b * brightnessScale, 1),
                       alpha: a)
    }

    private static func boosted(_ c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.deviceRGB) else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Boost saturation + brightness for vivid glow
        return NSColor(hue: h,
                       saturation: min(s * 1.3 + 0.1, 1),
                       brightness: min(b * 1.2 + 0.1, 1),
                       alpha: a)
    }
}
