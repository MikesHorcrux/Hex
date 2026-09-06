import HexCore
import SwiftUI

struct AgentApprovalModeMenu: View {
  @Binding var selection: HexAuthorizationMode
  let isEnabled: Bool
  let savedDefaultMode: HexAuthorizationMode
  let hasOverride: Bool
  let onUseSavedDefault: () -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: selection.permissionSymbol)
        Text(selection.permissionTitle)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
      .font(.caption)
      .foregroundStyle(selection == .fullAccess ? HexBrandPalette.warningInk : HexBrandPalette.ink)
      .padding(.horizontal, 9)
      .padding(.vertical, 6)
      .background(HexBrandPalette.hairline.opacity(0.45), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .help(
      isEnabled
        ? "Choose how Hex approves actions"
        : "Finish the current task or resolve conversation saving and recovery before changing permissions."
    )
    .accessibilityLabel("Action permissions: \(selection.permissionTitle)")
    .accessibilityIdentifier("composerApprovalModeMenu")
    .popover(isPresented: $isPresented, arrowEdge: .top) {
      HexApprovalModeOptionsView(
        selectedMode: selection,
        scopeDescription: hasOverride
          ? "Conversation override, starting with its next turn."
          : "Using the saved default for this conversation.",
        savedDefaultMode: savedDefaultMode,
        hasOverride: hasOverride,
        onUseSavedDefault: {
          guard isEnabled else { return }
          onUseSavedDefault()
          isPresented = false
        }
      ) { mode in
        guard isEnabled else { return }
        selection = mode
        isPresented = false
      }
    }
    .onChange(of: isEnabled) { _, enabled in
      if !enabled { isPresented = false }
    }
  }
}
