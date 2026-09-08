import AppKit
import SwiftUI

struct HexBrandMarkView: View {
  let size: CGFloat

  var body: some View {
    Image(nsImage: NSApplication.shared.applicationIconImage)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .shadow(color: HexBrandPalette.shadow, radius: size * 0.08, y: size * 0.04)
      .accessibilityHidden(true)
  }
}
