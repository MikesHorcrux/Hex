import SwiftUI

struct HexCodeScrollView<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    ScrollView([.vertical, .horizontal]) {
      content()
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
    }
    .defaultScrollAnchor(.topLeading, for: .alignment)
    .hexSurface(cornerRadius: 8, fill: HexBrandPalette.raisedSurface, shadowRadius: 0)
  }
}
