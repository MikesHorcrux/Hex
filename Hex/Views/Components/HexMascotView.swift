import SwiftUI

struct HexMascotView: View {
  let size: CGFloat

  var body: some View {
    Image("HexMascot")
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .shadow(color: HexBrandPalette.deepPlum.opacity(0.2), radius: size * 0.07, y: size * 0.04)
      .accessibilityHidden(true)
  }
}
