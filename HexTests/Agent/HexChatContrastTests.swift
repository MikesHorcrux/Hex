import AppKit
import SwiftUI
import Testing

@testable import Hex

@MainActor
@Suite("Chat contrast")
struct HexChatContrastTests {
  @Test(arguments: [
    NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua,
    .accessibilityHighContrastDarkAqua,
  ])
  func textAndPrimaryActionsMeetNormalTextContrast(_ name: NSAppearance.Name) throws {
    let appearance = try #require(NSAppearance(named: name))
    for background in [
      HexBrandPalette.canvas, HexBrandPalette.surface, HexBrandPalette.sidebarTint,
      HexBrandPalette.raisedSurface,
    ] {
      #expect(try contrast(HexBrandPalette.ink, background, appearance) >= 4.5)
      #expect(try contrast(HexBrandPalette.mutedInk, background, appearance) >= 4.5)
    }
    #expect(try contrast(HexBrandPalette.deepPlum, HexBrandPalette.pink, appearance) >= 4.5)
    #expect(try contrast(HexBrandPalette.deepPlum, HexBrandPalette.pinkPressed, appearance) >= 4.5)
    #expect(try contrast(HexBrandPalette.accentInk, HexBrandPalette.canvas, appearance) >= 4.5)
  }

  private func contrast(_ foreground: Color, _ background: Color, _ appearance: NSAppearance) throws
    -> Double
  {
    let first = try luminance(foreground, appearance)
    let second = try luminance(background, appearance)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
  }

  private func luminance(_ color: Color, _ appearance: NSAppearance) throws -> Double {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor(color).usingColorSpace(.sRGB)
    }
    let rgb = try #require(resolved)
    func linear(_ value: CGFloat) -> Double {
      value <= 0.04045 ? Double(value / 12.92) : pow(Double((value + 0.055) / 1.055), 2.4)
    }
    return linear(rgb.redComponent) * 0.2126 + linear(rgb.greenComponent) * 0.7152 + linear(
      rgb.blueComponent) * 0.0722
  }
}
