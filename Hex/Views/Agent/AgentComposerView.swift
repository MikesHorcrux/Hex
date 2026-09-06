import HexCore
import SwiftUI

struct AgentComposerView: View {
  @Binding var draft: String
  let availableModels: [AgentComposerModelOption]
  let availableEfforts: [AgentComposerEffort]
  let isLoadingModels: Bool
  let selectionNotice: String?
  @Binding var selectedModelID: String?
  @Binding var selectedEffort: AgentComposerEffort
  @Binding var selectedAuthorizationMode: HexAuthorizationMode
  let canChangeAuthorizationMode: Bool
  let savedAuthorizationMode: HexAuthorizationMode
  let hasAuthorizationOverride: Bool
  let onUseSavedAuthorizationMode: () -> Void
  let focus: FocusState<Bool>.Binding
  let canSend: Bool
  let canChangeOptions: Bool
  let isRunning: Bool
  let onSend: () -> Void
  let onCancel: () -> Void
  let onRefreshModels: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Message Hex")
          .font(.caption.weight(.bold))
          .tracking(0.5)
          .foregroundStyle(HexBrandPalette.ink)

        Spacer()

        Text("⌘ Return to send")
          .font(.caption2)
          .foregroundStyle(HexBrandPalette.mutedInk)
      }

      ZStack(alignment: .topLeading) {
        if draft.isEmpty {
          Text("What should we think through, build, or do?")
            .font(.body)
            .foregroundStyle(HexBrandPalette.mutedInk)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .allowsHitTesting(false)
        }

        TextEditor(text: $draft)
          .focused(focus)
          .font(.body)
          .foregroundStyle(HexBrandPalette.ink)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, -4)
          .frame(minHeight: 68, maxHeight: 148)
          .accessibilityLabel("Message Hex")
          .accessibilityIdentifier("promptComposer")
      }

      Rectangle()
        .fill(HexBrandPalette.hairline)
        .frame(height: 1)

      if let selectionNotice {
        Text(selectionNotice)
          .font(.caption)
          .foregroundStyle(HexBrandPalette.mutedInk)
      }

      AgentComposerControlsView(
        availableModels: availableModels, availableEfforts: availableEfforts,
        isLoadingModels: isLoadingModels,
        selectedModelID: $selectedModelID, selectedEffort: $selectedEffort,
        selectedAuthorizationMode: $selectedAuthorizationMode,
        canChangeAuthorizationMode: canChangeAuthorizationMode,
        savedAuthorizationMode: savedAuthorizationMode,
        hasAuthorizationOverride: hasAuthorizationOverride,
        onUseSavedAuthorizationMode: onUseSavedAuthorizationMode,
        canChangeOptions: canChangeOptions, canSend: canSend, isRunning: isRunning,
        onSend: onSend, onCancel: onCancel, onRefreshModels: onRefreshModels)
    }
    .padding(15)
    .frame(maxWidth: 860)
    .hexSurface(cornerRadius: 20, fill: HexBrandPalette.raisedSurface, shadowRadius: 12)
    .padding(.horizontal, 24)
    .padding(.bottom, 20)
  }
}
