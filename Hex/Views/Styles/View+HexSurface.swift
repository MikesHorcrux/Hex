import SwiftUI

extension View {
  func hexSurface(
    cornerRadius: CGFloat = 18,
    fill: Color = HexBrandPalette.surface,
    border: Color = HexBrandPalette.hairline,
    shadowRadius: CGFloat = 10
  ) -> some View {
    modifier(
      HexSurfaceStyle(
        cornerRadius: cornerRadius,
        fill: fill,
        border: border,
        shadowRadius: shadowRadius
      )
    )
  }
}
