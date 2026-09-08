import SwiftUI

struct HexSettingsPageHeaderView: View {
  let title: String
  let detail: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 14) {
      Image(systemName: systemImage)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(HexBrandPalette.accentInk)
        .frame(width: 42, height: 42)
        .background(HexBrandPalette.softCoral, in: Circle())
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title2.weight(.semibold))
          .foregroundStyle(HexBrandPalette.ink)
        Text(detail)
          .font(.callout)
          .foregroundStyle(HexBrandPalette.mutedInk)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 17)
    .background(HexBrandPalette.surface.opacity(0.72))
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(HexBrandPalette.hairline)
        .frame(height: 1)
    }
    .accessibilityElement(children: .combine)
  }
}
