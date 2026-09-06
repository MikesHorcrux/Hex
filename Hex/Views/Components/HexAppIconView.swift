import AppKit
import SwiftUI

struct HexAppIconView: View {
  let size: CGFloat

  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .shadow(color: HexBrandPalette.deepPlum.opacity(0.16), radius: size * 0.08, y: size * 0.04)
      .accessibilityHidden(true)
  }
}
