import HexCore
import SwiftUI

struct HexApprovalModeRow: View {
  let mode: HexAuthorizationMode
  let isSelected: Bool
  let onSelect: () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: mode.permissionSymbol)
          .frame(width: 18)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(mode.permissionTitle)
            .font(.callout.weight(.medium))
          Text(mode.permissionSummary)
            .font(.caption)
            .foregroundStyle(
              mode == .fullAccess ? HexBrandPalette.warningInk : HexBrandPalette.mutedInk
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Image(systemName: "checkmark")
          .font(.caption.weight(.semibold))
          .opacity(isSelected ? 1 : 0)
          .accessibilityHidden(true)
      }
      .foregroundStyle(mode == .fullAccess ? HexBrandPalette.warningInk : HexBrandPalette.ink)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isHovered ? HexBrandPalette.softCoral.opacity(0.4) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    // Preserve Button's native role and press action. An .ignore element replaces those semantics.
    .accessibilityLabel(mode.permissionTitle)
    .accessibilityHint(mode.permissionSummary)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("approvalMode-\(mode.rawValue)")
  }
}
