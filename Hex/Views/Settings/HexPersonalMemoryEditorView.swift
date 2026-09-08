import HexPersonality
import Observation
import SwiftUI

struct HexPersonalMemoryEditorView: View {
  @Bindable var model: HexPersonalMemoriesModel

  var body: some View {
    Section {
      LabeledContent("Scope") {
        Text(model.scope.rawValue)
          .font(.body.monospaced())
          .textSelection(.enabled)
          .accessibilityIdentifier("hexPersonalMemoryScopeValue")
      }

      Picker("Kind", selection: $model.draftKind) {
        ForEach(PersonalMemoryKind.allCases, id: \.self) { kind in
          Text(kindLabel(kind)).tag(kind)
        }
      }
      .accessibilityIdentifier("hexPersonalMemoryKindPicker")
      .disabled(model.isSaving)

      Picker("Source", selection: $model.draftSource) {
        ForEach(PersonalMemorySource.allCases, id: \.self) { source in
          Text(sourceLabel(source)).tag(source)
        }
      }
      .accessibilityIdentifier("hexPersonalMemorySourcePicker")
      .disabled(model.isSaving)

      TextEditor(text: $model.draftText)
        .font(.body)
        .frame(minHeight: 90, idealHeight: 120)
        .overlay(alignment: .topLeading) {
          if model.draftText.isEmpty {
            Text("Write a memory you want Hex to retain…")
              .foregroundStyle(.tertiary)
              .padding(.top, 8)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
        }
        .accessibilityIdentifier("hexPersonalMemoryTextEditor")
        .disabled(model.isSaving)

      Toggle("Pin this memory", isOn: $model.draftIsPinned)
        .accessibilityIdentifier("hexPersonalMemoryPinnedToggle")
        .disabled(model.isSaving)

      Text(
        "Saving is always explicit. Hex does not extract memories from chats, and the source label above should match what actually happened."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      HStack {
        Button("Cancel", action: model.cancelEditing)
          .buttonStyle(.hexSecondaryAction)
          .accessibilityIdentifier("hexPersonalMemoryCancelButton")
          .disabled(model.isSaving)

        Spacer()

        if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button(model.isEditing ? "Save changes" : "Add memory") {
          Task {
            await model.saveDraft()
          }
        }
        .buttonStyle(.hexPrimaryAction)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("hexPersonalMemorySaveButton")
        .disabled(!model.canSaveDraft)
      }
    } header: {
      Text(model.editorTitle)
    }
    .accessibilityIdentifier("hexPersonalMemoryEditor")
  }

  private func kindLabel(_ kind: PersonalMemoryKind) -> String {
    switch kind {
    case .preference:
      "Preference"
    case .fact:
      "Fact"
    case .relationship:
      "Relationship"
    case .projectContext:
      "Project context"
    }
  }

  private func sourceLabel(_ source: PersonalMemorySource) -> String {
    switch source {
    case .explicitUserStatement:
      "You told Hex"
    case .explicitUserCorrection:
      "You corrected Hex"
    case .userApprovedSuggestion:
      "You approved a suggestion"
    }
  }
}
