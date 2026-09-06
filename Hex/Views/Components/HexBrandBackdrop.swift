import SwiftUI

struct HexBrandBackdrop: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          HexBrandPalette.coralPressed,
          HexBrandPalette.coral,
          HexBrandPalette.pink,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      RadialGradient(
        colors: [
          HexBrandPalette.cream.opacity(0.42),
          Color.clear,
        ],
        center: .topTrailing,
        startRadius: 0,
        endRadius: 520
      )

      LinearGradient(
        colors: [
          Color.clear,
          HexBrandPalette.deepPlum.opacity(0.12),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .accessibilityHidden(true)
  }
}
