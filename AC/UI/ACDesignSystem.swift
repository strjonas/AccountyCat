//
//  ACDesignSystem.swift
//  AC
//
//  Shared design tokens — palette, typography, animation curves, dimensions,
//  radii, shadows, and button styles. All accent-aware components read the
//  current character accent from the environment so the whole UI re-tints
//  when the user picks a different character.
//

import AppKit
import SwiftUI

// MARK: - Color Palette (legacy / shared)

extension Color {
    // Warm neutrals
    static let acCream        = Color(red: 1.00, green: 0.97, blue: 0.93)
    static let acPaper        = Color(red: 0.99, green: 0.96, blue: 0.90)

    // Caramel accent (Mochi default — also used as fallback when env accent is absent)
    static let acCaramel      = Color(red: 0.91, green: 0.66, blue: 0.35)
    static let acCaramelLight = Color(red: 0.97, green: 0.83, blue: 0.63)
    static let acCaramelSoft  = Color(red: 0.98, green: 0.90, blue: 0.75)

    // Blush & amber
    static let acBlush        = Color(red: 1.00, green: 0.74, blue: 0.78)
    static let acAmber        = Color(red: 0.98, green: 0.76, blue: 0.35)

    // Cat face
    static let acFur          = Color(red: 0.98, green: 0.85, blue: 0.60)
    static let acFurDark      = Color(red: 0.92, green: 0.70, blue: 0.43)
    static let acEyeColor     = Color(red: 0.28, green: 0.20, blue: 0.15)
    static let acNoseColor    = Color(red: 0.82, green: 0.43, blue: 0.43)
    static let acWhiskerColor = Color(red: 0.52, green: 0.36, blue: 0.24)

    // Text — adapts to light / dark mode
    static let acTextPrimary  = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.94, alpha: 1)
            : NSColor(red: 0.16, green: 0.11, blue: 0.07, alpha: 1)
    })

    /// Neutral surface fill that reads as a subtle card on either appearance.
    static let acSurface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.045)
            : NSColor(white: 0.0, alpha: 0.025)
    })

    /// Hairline stroke that reads on both appearances.
    static let acHairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.10)
            : NSColor(white: 0.0, alpha: 0.08)
    })
}

// MARK: - Typography

extension Font {
    /// Rounded system font — friendly and cohesive throughout the app.
    static func ac(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Animation

extension Animation {
    /// Responsive spring for interactions (expansions, mood changes).
    static let acSpring = Animation.spring(response: 0.44, dampingFraction: 0.68)
    /// Snappier spring for tab switches and small toggles.
    static let acSnap   = Animation.spring(response: 0.30, dampingFraction: 0.78)
    /// Smooth fade for opacity and colour transitions.
    static let acFade   = Animation.easeInOut(duration: 0.26)
}

// MARK: - Dimensions

enum ACD {
    static let orbDiameter: CGFloat  = 72
    static let panelWidth: CGFloat   = 200
    static let panelHeight: CGFloat  = 240
    static let popoverWidth: CGFloat = 472
}

/// Unified corner radii. Reach for these instead of literals so
/// surfaces nest consistently across the whole UI.
enum ACRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

/// Spacing scale.
enum ACSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}

// MARK: - Accent environment

private struct ACAccentKey: EnvironmentKey {
    static let defaultValue: Color = Color(red: 0.91, green: 0.66, blue: 0.35) // Mochi
}

private struct ACAccentLightKey: EnvironmentKey {
    static let defaultValue: Color = Color(red: 0.97, green: 0.83, blue: 0.63)
}

private struct ACAccentSoftKey: EnvironmentKey {
    static let defaultValue: Color = Color(red: 0.98, green: 0.90, blue: 0.75)
}

extension EnvironmentValues {
    var acAccent: Color {
        get { self[ACAccentKey.self] }
        set { self[ACAccentKey.self] = newValue }
    }
    var acAccentLight: Color {
        get { self[ACAccentLightKey.self] }
        set { self[ACAccentLightKey.self] = newValue }
    }
    var acAccentSoft: Color {
        get { self[ACAccentSoftKey.self] }
        set { self[ACAccentSoftKey.self] = newValue }
    }
}

extension View {
    /// Inject the accent palette of a character into this view subtree.
    /// Every accent-aware component re-tints automatically.
    func acAccent(for character: ACCharacter) -> some View {
        self
            .environment(\.acAccent, character.accentColor)
            .environment(\.acAccentLight, character.accentLight)
            .environment(\.acAccentSoft, character.accentSoft)
            .tint(character.accentColor)
    }
}

// MARK: - Button Styles

/// Filled accent action — used for the most important call to action in a row.
struct ACPrimaryButton: ButtonStyle {
    @Environment(\.acAccent) private var accent
    @Environment(\.acAccentLight) private var accentLight

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accentLight, accent.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
                    )
                    .shadow(color: accent.opacity(0.22), radius: 6, y: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.96 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

/// Quiet neutral button — supporting actions next to a primary.
struct ACSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .medium))
            .foregroundStyle(Color.acTextPrimary.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.acSurface)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.acHairline, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

/// Destructive action (Reset, Quit). Red is universal — does not change with character.
struct ACDangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(configuration.isPressed ? 0.78 : 0.88))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

/// Subtle icon-only button — circular hit target with a hairline ring.
struct ACIconButton: ButtonStyle {
    var size: CGFloat = 28
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.acTextPrimary.opacity(0.72))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.acSurface)
                    .overlay(Circle().stroke(Color.acHairline, lineWidth: 1))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

// MARK: - Character Palette

extension ACCharacter {
    // MARK: Orb gradient
    var orbTopColor: Color {
        switch self {
        case .mochi: return Color(red: 1.00, green: 0.96, blue: 0.89)
        case .nova:  return Color(red: 0.87, green: 0.89, blue: 1.00)
        case .sage:  return Color(red: 0.88, green: 0.97, blue: 0.90)
        }
    }
    var orbBottomColor: Color {
        switch self {
        case .mochi: return Color(red: 0.98, green: 0.88, blue: 0.72)
        case .nova:  return Color(red: 0.72, green: 0.76, blue: 0.98)
        case .sage:  return Color(red: 0.70, green: 0.89, blue: 0.76)
        }
    }
    var nudgingOrbTopColor: Color {
        switch self {
        case .mochi: return Color(red: 1.00, green: 0.95, blue: 0.78)
        case .nova:  return Color(red: 0.80, green: 0.84, blue: 1.00)
        case .sage:  return Color(red: 0.82, green: 0.97, blue: 0.85)
        }
    }
    var nudgingOrbBottomColor: Color {
        switch self {
        case .mochi: return Color(red: 0.98, green: 0.82, blue: 0.52)
        case .nova:  return Color(red: 0.55, green: 0.62, blue: 0.97)
        case .sage:  return Color(red: 0.48, green: 0.82, blue: 0.60)
        }
    }

    // MARK: Accent — replaces acCaramel / acCaramelLight / acCaramelSoft
    var accentColor: Color {
        switch self {
        case .mochi: return Color(red: 0.91, green: 0.66, blue: 0.35)
        case .nova:  return Color(red: 0.44, green: 0.48, blue: 0.92)
        case .sage:  return Color(red: 0.26, green: 0.65, blue: 0.46)
        }
    }
    var accentLight: Color {
        switch self {
        case .mochi: return Color(red: 0.97, green: 0.83, blue: 0.63)
        case .nova:  return Color(red: 0.78, green: 0.80, blue: 0.98)
        case .sage:  return Color(red: 0.72, green: 0.90, blue: 0.78)
        }
    }
    var accentSoft: Color {
        switch self {
        case .mochi: return Color(red: 0.98, green: 0.90, blue: 0.75)
        case .nova:  return Color(red: 0.90, green: 0.91, blue: 0.99)
        case .sage:  return Color(red: 0.89, green: 0.97, blue: 0.91)
        }
    }

    // MARK: Ring (pulse ring on nudge / escalate)
    var ringColor: Color {
        switch self {
        case .mochi: return Color(red: 0.98, green: 0.76, blue: 0.35)
        case .nova:  return Color(red: 0.55, green: 0.60, blue: 0.97)
        case .sage:  return Color(red: 0.30, green: 0.72, blue: 0.52)
        }
    }
    var escalatedRingColor: Color {
        switch self {
        case .mochi: return Color(red: 0.97, green: 0.60, blue: 0.35)
        case .nova:  return Color(red: 0.75, green: 0.40, blue: 0.95)
        case .sage:  return Color(red: 0.85, green: 0.55, blue: 0.30)
        }
    }
    var shadowColor: Color {
        switch self {
        case .mochi: return Color(red: 0.75, green: 0.60, blue: 0.40)
        case .nova:  return Color(red: 0.44, green: 0.48, blue: 0.75)
        case .sage:  return Color(red: 0.26, green: 0.55, blue: 0.38)
        }
    }

    // MARK: Header gradient
    var headerLightTop: Color {
        switch self {
        case .mochi: return Color(red: 1.00, green: 0.97, blue: 0.93)
        case .nova:  return Color(red: 0.93, green: 0.94, blue: 1.00)
        case .sage:  return Color(red: 0.93, green: 0.99, blue: 0.94)
        }
    }
    var headerLightBottom: Color {
        switch self {
        case .mochi: return Color(red: 0.99, green: 0.94, blue: 0.87)
        case .nova:  return Color(red: 0.87, green: 0.89, blue: 0.99)
        case .sage:  return Color(red: 0.87, green: 0.97, blue: 0.89)
        }
    }
    var headerDarkTop: Color {
        switch self {
        case .mochi: return Color(red: 0.22, green: 0.18, blue: 0.13)
        case .nova:  return Color(red: 0.13, green: 0.14, blue: 0.24)
        case .sage:  return Color(red: 0.11, green: 0.19, blue: 0.15)
        }
    }
    var headerDarkBottom: Color {
        switch self {
        case .mochi: return Color(red: 0.18, green: 0.14, blue: 0.09)
        case .nova:  return Color(red: 0.09, green: 0.10, blue: 0.19)
        case .sage:  return Color(red: 0.08, green: 0.14, blue: 0.11)
        }
    }

    // MARK: Display

    /// Short personality label rendered next to the character name.
    var moodLabel: String {
        switch self {
        case .mochi: return "warm"
        case .nova:  return "sharp"
        case .sage:  return "calm"
        }
    }
}
