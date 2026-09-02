import Observation
import SwiftUI

struct HexPersonalityProfileView: View {
  @Bindable var model: HexPersonalityProfileModel

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
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("hexPersonalityProfileError")
      }

      if let statusMessage = model.statusMessage {
        Label(statusMessage, systemImage: "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("hexPersonalityProfileStatus")
      }

      HStack {
        Button("Try Again") {
          Task {
            await model.reload()
          }
        }
        .accessibilityIdentifier("hexPersonalityProfileRetryButton")
        .disabled(model.isLoading || model.isSaving)

        Spacer()

        if model.isSaving {
          ProgressView()
            .controlSize(.small)
        }
        Button("Save profile") {
          Task {
            await model.save()
          }
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("hexPersonalityProfileSaveButton")
        .disabled(!model.canSave)
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
      Label(
        "No personality profile is saved yet. Add the fields above and save when you are ready.",
        systemImage: "person.crop.circle.badge.plus"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("hexPersonalityProfileEmptyState")
    case .loaded:
      EmptyView()
    case .corrupted(let message), .unavailable(let message), .failed(let message):
      Label(message, systemImage: model.state.isUnavailable ? "nosign" : "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(model.state.isUnavailable ? Color.secondary : Color.orange)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("hexPersonalityProfileStateMessage")
    }
  }
}
