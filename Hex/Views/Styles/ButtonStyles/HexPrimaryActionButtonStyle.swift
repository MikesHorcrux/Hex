import SwiftUI

struct HexPrimaryActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 15)
      .padding(.vertical, 8)
      .background(
        configuration.isPressed ? HexBrandPalette.coralPressed : HexBrandPalette.coral,
        in: Capsule()
      )
      .overlay {
        Capsule()
          .strokeBorder(.white.opacity(0.22), lineWidth: 1)
      }
      .shadow(
        color: HexBrandPalette.coral.opacity(configuration.isPressed ? 0.08 : 0.24),
        radius: configuration.isPressed ? 2 : 7,
        y: configuration.isPressed ? 1 : 3
      )
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .opacity(isEnabled ? 1 : 0.46)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
  }
}
