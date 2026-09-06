import HexCore
import SwiftUI

struct HexApprovalModeOptionsView: View {
  let selectedMode: HexAuthorizationMode
  let scopeDescription: String
  var savedDefaultMode: HexAuthorizationMode? = nil
  var hasOverride = false
  var onUseSavedDefault: (() -> Void)? = nil
  let onSelect: (HexAuthorizationMode) -> Void
  @State private var showsDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("How should Hex’s actions be approved?")
          .font(.caption)
          .foregroundStyle(HexBrandPalette.mutedInk)
        Spacer(minLength: 8)
        Button {
          showsDetails.toggle()
        } label: {
          Text(showsDetails ? "Less" : "Learn more").underline()
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(HexBrandPalette.mutedInk)
        .accessibilityHint("Explains Hex approvals and macOS privacy permissions")
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 4)

      ForEach(HexAuthorizationMode.allCases) { mode in
        HexApprovalModeRow(mode: mode, isSelected: mode == selectedMode) {
          onSelect(mode)
        }
      }

      Text(scopeDescription)
        .font(.caption2)
        .foregroundStyle(HexBrandPalette.mutedInk)
        .padding(.horizontal, 10)
        .padding(.top, 5)

      if let savedDefaultMode {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("Saved default: \(savedDefaultMode.permissionTitle)")
            .foregroundStyle(HexBrandPalette.mutedInk)
          Spacer(minLength: 0)
          if hasOverride, let onUseSavedDefault {
            Button("Use saved default", action: onUseSavedDefault)
              .buttonStyle(.link)
              .accessibilityHint(
                "Clears only this conversation’s permission override. The saved default is \(savedDefaultMode.permissionTitle)."
              )
              .accessibilityIdentifier("useSavedApprovalDefault")
          }
        }
        .font(.caption2)
        .padding(.horizontal, 10)
        .padding(.top, 3)
      }

      if showsDetails {
        Divider().padding(.vertical, 6)
        Text(
          "These are Hex’s action approvals, not macOS permissions. Existing access grants still apply in Ask for approval and Approve for me. Full access can run commands with your Mac account’s file and network access, including outside the selected workspace. Tool-specific checks and macOS privacy controls still apply; commands are not sandboxed by Hex."
        )
        .font(.caption)
        .foregroundStyle(HexBrandPalette.mutedInk)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
      }
    }
    .padding(10)
    .frame(width: 420)
    .background(HexBrandPalette.raisedSurface)
  }
}
