import SwiftUI
import CoreText

/// SourcePath Labs design tokens (see design/08-style or memory). Dark navy +
/// cyan accent + glow, with Inter (body) and Space Grotesk (display).
/// Mirrors `~/dev/alexander/app/ui/fred.css` `:root`.
enum Theme {
    // MARK: Palette
    static let bg = Color(hex: 0x0A0F1E)
    static let bgDeep = Color(hex: 0x07091A)
    static let surface = Color(hex: 0x111827)
    static let surfaceStrong = Color(hex: 0x1A2238)
    static let surfaceSoft = Color.white.opacity(0.03)
    static let accent = Color(hex: 0x00F0FF)
    static let accentHover = Color(hex: 0x00E0EE)
    static let accentSoft = Color(hex: 0x00F0FF).opacity(0.10)
    static let textPrimary = Color.white
    static let textBody = Color(hex: 0xC4D0FF)
    static let textMuted = Color(hex: 0xA5B4FC)
    static let textFaint = Color(hex: 0x6E7AB8)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.16)

    // MARK: Shape
    static let radiusLg: CGFloat = 20
    static let radiusMd: CGFloat = 14
    static let radiusSm: CGFloat = 10
    static let radiusXs: CGFloat = 8

    // MARK: Type — Space Grotesk (display), Inter (body), SF Mono (mono)
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("Space Grotesk", size: size).weight(weight)
    }
    static func body(_ size: CGFloat = 13, _ weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, design: .monospaced)
    }

    /// The soft cyan glow used on accents/CTAs.
    static let glow = Color(hex: 0x00F0FF).opacity(0.45)

    /// Registers the bundled OFL fonts. Call once at launch.
    static func registerFonts() {
        for name in ["Inter-Variable", "SpaceGrotesk-Variable"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
