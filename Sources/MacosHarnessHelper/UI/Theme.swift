import AppKit
import SwiftUI

/// Control Tower palette: the design canvas's tokens, resolved per appearance.
enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static let surface = dynamic(light: 0xFFFFFF, dark: 0x262626)
    static let card = dynamic(light: 0xF5F5F5, dark: 0x303030)
    static let chip = dynamic(light: 0xF0F0F0, dark: 0x303030)
    static let inset = dynamic(light: 0xF0F0F0, dark: 0x1F1F1F)
    static let textPrimary = dynamic(light: 0x1A1A1A, dark: 0xF4F4F4)
    static let textSecondary = dynamic(light: 0x4D4D4D, dark: 0xB3B3B3)
    static let textMuted = dynamic(light: 0x696969, dark: 0x8C8C8C)
    static let border = dynamic(light: 0xD5D5D5, dark: 0xFFFFFF, darkAlpha: 0.16)
    static let hairline = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.12)

    static let accent = Color(nsColor: NSColor(hex: 0xFF450F))
    /// The darker orange, for filled buttons with white text.
    static let accentStrong = Color(nsColor: NSColor(hex: 0xD93100))
    static let accentText = dynamic(light: 0xB32800, dark: 0xFF8866)
    static let accentTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: 0xFF450F, alpha: 0.18) : NSColor(hex: 0xFDF0ED)
    })

    static let success = dynamic(light: 0x2E7D32, dark: 0x4CAF50)
    static let successText = dynamic(light: 0x2E7D32, dark: 0x81C784)
    static let primaryFill = dynamic(light: 0x000000, dark: 0xF4F4F4)
    static let primaryText = dynamic(light: 0xFFFFFF, dark: 0x1A1A1A)

    static let accentNS = NSColor(hex: 0xFF450F)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
