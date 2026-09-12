import AppKit
import SwiftUI

enum HexBrandPalette {
  // Keep text and legacy tinted controls readable; pale pink is reserved for filled accents.
  static let coral = accentInk
  static let coralPressed = Color(red: 0.63, green: 0.14, blue: 0.30)
  static let pinkPressed = Color(red: 0.91, green: 0.43, blue: 0.55)
  static let pink = Color(red: 0.98, green: 0.58, blue: 0.67)
  static let apricot = Color(red: 1.00, green: 0.70, blue: 0.43)
  static let cream = Color(red: 1.00, green: 0.95, blue: 0.84)
  static let deepPlum = Color(red: 0.10, green: 0.11, blue: 0.14)
  static let accentInk = adaptive(
    light: NSColor(srgbRed: 0.66, green: 0.17, blue: 0.33, alpha: 1),
    dark: NSColor(srgbRed: 1.00, green: 0.55, blue: 0.65, alpha: 1)
  )

  static let canvas = adaptive(
    light: NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1),
    dark: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
  )
  static let surface = adaptive(
    light: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 0.98),
    dark: NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 0.98)
  )
  static let raisedSurface = adaptive(
    light: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    dark: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1)
  )
  static let sidebarTint = adaptive(
    light: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1),
    dark: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
  )
  static let softCoral = adaptive(
    light: NSColor(srgbRed: 0.99, green: 0.89, blue: 0.92, alpha: 1),
    dark: NSColor(srgbRed: 0.29, green: 0.18, blue: 0.22, alpha: 1)
  )
  static let softApricot = adaptive(
    light: NSColor(srgbRed: 1.00, green: 0.91, blue: 0.76, alpha: 1),
    dark: NSColor(srgbRed: 0.36, green: 0.23, blue: 0.15, alpha: 1)
  )
  static let ink = adaptive(
    light: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1),
    dark: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
  )
  static let mutedInk = adaptive(
    light: NSColor(srgbRed: 0.39, green: 0.41, blue: 0.45, alpha: 1),
    dark: NSColor(srgbRed: 0.68, green: 0.69, blue: 0.73, alpha: 1)
  )
  static let successInk = adaptive(
    light: NSColor(srgbRed: 0.11, green: 0.42, blue: 0.22, alpha: 1),
    dark: NSColor(srgbRed: 0.50, green: 0.90, blue: 0.62, alpha: 1)
  )
  static let successOnCream = Color(red: 0.11, green: 0.42, blue: 0.22)
  static let warningInk = adaptive(
    light: NSColor(srgbRed: 0.69, green: 0.25, blue: 0.02, alpha: 1),
    dark: NSColor(srgbRed: 1.00, green: 0.61, blue: 0.23, alpha: 1)
  )
  static let hairline = adaptive(
    light: NSColor(srgbRed: 0.20, green: 0.22, blue: 0.28, alpha: 0.16),
    dark: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.90, alpha: 0.18),
    highContrastLight: NSColor(srgbRed: 0.42, green: 0.43, blue: 0.46, alpha: 1),
    highContrastDark: NSColor(srgbRed: 0.66, green: 0.67, blue: 0.70, alpha: 1)
  )
  static let shadow = Color.black.opacity(0.12)

  private static func adaptive(
    light: NSColor, dark: NSColor,
    highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [
          .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ]) {
        case .accessibilityHighContrastAqua: highContrastLight ?? light
        case .accessibilityHighContrastDarkAqua: highContrastDark ?? dark
        case .darkAqua: dark
        default: light
        }
      }
    )
  }
}
