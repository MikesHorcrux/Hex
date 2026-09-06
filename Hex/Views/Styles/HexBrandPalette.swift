import AppKit
import SwiftUI

enum HexBrandPalette {
  static let coral = Color(red: 0.86, green: 0.20, blue: 0.30)
  static let coralPressed = Color(red: 0.75, green: 0.13, blue: 0.24)
  static let pink = Color(red: 0.98, green: 0.58, blue: 0.67)
  static let apricot = Color(red: 1.00, green: 0.70, blue: 0.43)
  static let cream = Color(red: 1.00, green: 0.95, blue: 0.84)
  static let deepPlum = Color(red: 0.24, green: 0.08, blue: 0.21)
  static let accentInk = adaptive(
    light: NSColor(srgbRed: 0.66, green: 0.08, blue: 0.19, alpha: 1),
    dark: NSColor(srgbRed: 1.00, green: 0.55, blue: 0.65, alpha: 1)
  )

  static let canvas = adaptive(
    light: NSColor(srgbRed: 1.00, green: 0.98, blue: 0.94, alpha: 1),
    dark: NSColor(srgbRed: 0.12, green: 0.07, blue: 0.11, alpha: 1)
  )
  static let surface = adaptive(
    light: NSColor(srgbRed: 1.00, green: 0.96, blue: 0.89, alpha: 0.98),
    dark: NSColor(srgbRed: 0.20, green: 0.12, blue: 0.18, alpha: 0.98)
  )
  static let raisedSurface = adaptive(
    light: NSColor(srgbRed: 1.00, green: 0.99, blue: 0.97, alpha: 1),
    dark: NSColor(srgbRed: 0.25, green: 0.15, blue: 0.22, alpha: 1)
  )
  static let sidebarTint = adaptive(
    light: NSColor(srgbRed: 0.99, green: 0.88, blue: 0.86, alpha: 0.72),
    dark: NSColor(srgbRed: 0.19, green: 0.09, blue: 0.17, alpha: 0.82)
  )
  static let softCoral = adaptive(
    light: NSColor(srgbRed: 1.00, green: 0.86, blue: 0.84, alpha: 1),
    dark: NSColor(srgbRed: 0.39, green: 0.16, blue: 0.22, alpha: 1)
  )
  static let softApricot = adaptive(
    light: NSColor(srgbRed: 1.00, green: 0.91, blue: 0.76, alpha: 1),
    dark: NSColor(srgbRed: 0.36, green: 0.23, blue: 0.15, alpha: 1)
  )
  static let ink = adaptive(
    light: NSColor(srgbRed: 0.24, green: 0.08, blue: 0.21, alpha: 1),
    dark: NSColor(srgbRed: 1.00, green: 0.95, blue: 0.88, alpha: 1)
  )
  static let mutedInk = adaptive(
    light: NSColor(srgbRed: 0.43, green: 0.30, blue: 0.39, alpha: 1),
    dark: NSColor(srgbRed: 0.80, green: 0.69, blue: 0.75, alpha: 1)
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
    light: NSColor(srgbRed: 0.42, green: 0.15, blue: 0.31, alpha: 0.16),
    dark: NSColor(srgbRed: 1.00, green: 0.78, blue: 0.80, alpha: 0.16)
  )
  static let shadow = Color.black.opacity(0.12)

  private static func adaptive(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      }
    )
  }
}
