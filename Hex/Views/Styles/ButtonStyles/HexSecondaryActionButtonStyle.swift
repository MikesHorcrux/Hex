import SwiftUI

struct HexSecondaryActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(HexBrandPalette.ink)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(
        configuration.isPressed ? HexBrandPalette.softCoral : HexBrandPalette.raisedSurface,
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(HexBrandPalette.hairline, lineWidth: 1)
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .opacity(isEnabled ? 1 : 0.46)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
