import SwiftUI

struct HexInlineNoticeView: View {
  let message: String
  let systemImage: String
  let tint: Color
  let foreground: Color

  init(
    message: String,
    systemImage: String,
    tint: Color,
    foreground: Color = HexBrandPalette.ink
  ) {
    self.message = message
    self.systemImage = systemImage
    self.tint = tint
    self.foreground = foreground
  }

  var body: some View {
    Label(message, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(foreground)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 11))
      .overlay {
        RoundedRectangle(cornerRadius: 11)
          .strokeBorder(tint.opacity(0.24), lineWidth: 1)
      }
  }
}
