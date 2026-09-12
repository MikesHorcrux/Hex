import SwiftUI

struct HexPrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(HexBrandPalette.deepPlum)
      .padding(.horizontal, 15)
      .padding(.vertical, 8)
      .background(
        configuration.isPressed ? HexBrandPalette.pinkPressed : HexBrandPalette.pink,
        in: Capsule()
      )
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .opacity(isEnabled ? 1 : 0.46)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
