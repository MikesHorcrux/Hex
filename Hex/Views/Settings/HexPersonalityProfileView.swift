import Observation
import SwiftUI

struct HexPersonalityProfileView: View {
  @Bindable var model: HexPersonalityProfileModel
  let showsSaveAction: Bool

  init(model: HexPersonalityProfileModel, showsSaveAction: Bool = true) {
    _model = Bindable(model)
    self.showsSaveAction = showsSaveAction
  }

  var body: some View {
    Section {
      if model.isLoading {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Loading personality profile…")
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("hexPersonalityProfileLoading")
      }

      stateNotice

      TextField("Name", text: $model.name)
        .accessibilityIdentifier("hexPersonalityProfileNameField")
        .disabled(!model.canEdit)

      LabeledContent("Identity") {
        TextEditor(text: $model.identity)
          .font(.body)
          .frame(minHeight: 72, idealHeight: 96)
          .accessibilityIdentifier("hexPersonalityProfileIdentityField")
          .disabled(!model.canEdit)
      }

      LabeledContent("Voice") {
        TextEditor(text: $model.voice)
          .font(.body)
          .frame(minHeight: 72, idealHeight: 96)
          .accessibilityIdentifier("hexPersonalityProfileVoiceField")
          .disabled(!model.canEdit)
      }

      if let errorMessage = model.errorMessage {
        HexInlineNoticeView(
          message: errorMessage,
          systemImage: "exclamationmark.triangle.fill",
          tint: .orange
        )
        .accessibilityIdentifier("hexPersonalityProfileError")
      }

      if let statusMessage = model.statusMessage {
        HexInlineNoticeView(
          message: statusMessage,
          systemImage: "checkmark.circle.fill",
          tint: HexBrandPalette.successInk
        )
        .accessibilityIdentifier("hexPersonalityProfileStatus")
      }

      HStack {
        Button("Try Again") {
          Task {
            await model.reload()
          }
        }
        .buttonStyle(.hexSecondaryAction)
        .accessibilityIdentifier("hexPersonalityProfileRetryButton")
        .disabled(model.isLoading || model.isSaving)

        Spacer()

        if showsSaveAction {
          if model.isSaving {
            ProgressView()
              .controlSize(.small)
          }
          Button("Save profile") {
            Task {
              await model.save()
            }
          }
          .buttonStyle(.hexPrimaryAction)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("hexPersonalityProfileSaveButton")
          .disabled(!model.canSave)
        }
      }
    } header: {
      Text("Personality profile")
    } footer: {
      Text(
        "This profile is explicit user-owned context. Hex does not infer or rewrite it from conversations."
      )
    }
    .task {
      await model.load()
    }
    .accessibilityIdentifier("hexPersonalityProfileView")

    HexPersonalityProfileCollectionView(
      title: "Traits",
      prompt: "For example: curious, patient, concise",
      fieldIdentifier: "hexPersonalityProfileTraitsField",
      text: $model.traitsText
    )
    .disabled(!model.canEdit)

    HexPersonalityProfileCollectionView(
      title: "Values",
      prompt: "For example: user agency, honest evidence",
      fieldIdentifier: "hexPersonalityProfileValuesField",
      text: $model.valuesText
    )
    .disabled(!model.canEdit)

    HexPersonalityProfileCollectionView(
      title: "Boundaries",
      prompt: "For example: ask before sending, never invent completion",
      fieldIdentifier: "hexPersonalityProfileBoundariesField",
      text: $model.boundariesText
    )
    .disabled(!model.canEdit)
  }

  @ViewBuilder
  private var stateNotice: some View {
    switch model.state {
    case .idle:
      EmptyView()
    case .loading:
      EmptyView()
    case .empty:
      HexInlineNoticeView(
        message: "No personality is saved yet. Add only what you want Hex to know.",
        systemImage: "person.crop.circle.badge.plus",
        tint: HexBrandPalette.coral
      )
      .accessibilityIdentifier("hexPersonalityProfileEmptyState")
    case .loaded:
      EmptyView()
    case .corrupted(let message), .unavailable(let message), .failed(let message):
      HexInlineNoticeView(
        message: message,
        systemImage: model.state.isUnavailable ? "nosign" : "exclamationmark.triangle",
        tint: model.state.isUnavailable ? HexBrandPalette.mutedInk : .orange
      )
      .accessibilityIdentifier("hexPersonalityProfileStateMessage")
    }
  }
}
