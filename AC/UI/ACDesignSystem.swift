//
//  ACDesignSystem.swift
//  AC
//
//  Shared design tokens — palette, typography, animation curves, dimensions, and button styles.
//

import AppKit
import SwiftUI

// MARK: - Color Palette

extension Color {
    // Warm neutrals
    static let acCream        = Color(red: 1.00, green: 0.97, blue: 0.93)
    static let acPaper        = Color(red: 0.99, green: 0.96, blue: 0.90)

    // Caramel accent
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
            ? NSColor(white: 0.92, alpha: 1)   // near-white in dark mode
            : NSColor(red: 0.18, green: 0.12, blue: 0.08, alpha: 1) // warm dark brown in light mode
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
    static let panelHeight: CGFloat  = 240   // room for bubble (with thumbs row) above orb
    static let popoverWidth: CGFloat = 472
}

// MARK: - Button Styles

/// Warm caramel primary action button.
struct ACPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13, weight: .semibold))
            .foregroundStyle(Color(red: 0.20, green: 0.12, blue: 0.05))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.acCaramelLight))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.acSnap, value: configuration.isPressed)
    }
}

/// Neutral secondary action button.
struct ACSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ac(13))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
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

    // MARK: Header gradient (light / dark handled in ContentView)
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
}
