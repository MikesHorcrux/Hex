import SwiftUI

struct HexSurfaceStyle: ViewModifier {
  let cornerRadius: CGFloat
  let fill: Color
  let border: Color
  let shadowRadius: CGFloat

  func body(content: Content) -> some View {
    content
      .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(border, lineWidth: 1)
      }
      .shadow(color: HexBrandPalette.shadow, radius: shadowRadius, y: 3)
  }
}
