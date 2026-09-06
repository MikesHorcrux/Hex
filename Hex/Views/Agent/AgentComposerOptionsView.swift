import HexCore
import SwiftUI

struct AgentComposerOptionsView: View {
  let models: [AgentComposerModelOption]
  let efforts: [AgentComposerEffort]
  @Binding var selectedModelID: String?
  @Binding var selectedEffort: AgentComposerEffort
  let isEnabled: Bool
  let isLoading: Bool
  let onRefresh: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        Button {
          selectedModelID = nil
        } label: {
          selectionLabel("Automatic", isSelected: selectedModelID == nil)
        }

        if !models.isEmpty {
          Divider()
        }

        ForEach(models) { model in
          Button {
            selectedModelID = model.id.rawValue
          } label: {
            selectionLabel(model.displayName, isSelected: selectedModelID == model.id.rawValue)
          }
        }
        Divider()
        Button(isLoading ? "Refreshing models…" : "Refresh models", action: onRefresh)
          .disabled(isLoading)
      } label: {
        compactLabel(
          title: "Model",
          value: selectedModelName,
          systemImage: "cpu"
        )
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Model: \(selectedModelName)")
      .accessibilityIdentifier("composerModelMenu")

      Menu {
        ForEach(efforts) { effort in
          Button {
            selectedEffort = effort
          } label: {
            selectionLabel(effort.displayName, isSelected: selectedEffort == effort)
          }
        }
      } label: {
        compactLabel(
          title: "Effort",
          value: selectedEffort.displayName,
          systemImage: "gauge.with.dots.needle.33percent"
        )
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Effort: \(selectedEffort.displayName)")
      .accessibilityIdentifier("composerEffortMenu")
    }
    .disabled(!isEnabled)
  }

  private var selectedModelName: String {
    guard
      let selectedModelID,
      let model = models.first(where: { $0.id.rawValue == selectedModelID })
    else {
      return selectedModelID == nil ? "Automatic" : "Unavailable model"
    }
    return model.displayName
  }

  private func compactLabel(
    title: String,
    value: String,
    systemImage: String
  ) -> some View {
    HStack(spacing: 5) {
      Image(systemName: systemImage)
      // Native macOS Menu labels keep one text title. Separate Text nodes can silently drop
      // the selected value while Accessibility still reports it, hiding which model will run.
      Text("\(title): \(value)")
        .fontWeight(.semibold)
      Image(systemName: "chevron.down")
        .font(.caption2.weight(.bold))
        .foregroundStyle(HexBrandPalette.mutedInk)
    }
    .font(.caption)
    .foregroundStyle(HexBrandPalette.ink)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(HexBrandPalette.softCoral.opacity(0.36), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func selectionLabel(_ title: String, isSelected: Bool) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }
}
