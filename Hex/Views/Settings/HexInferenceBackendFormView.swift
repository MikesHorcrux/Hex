import HexCore
import Observation
import SwiftUI

struct HexInferenceBackendFormView: View {
  @Bindable var model: HexInferenceBackendSettingsModel
  let showsAdvancedConfiguration: Bool

  var body: some View {
    Section {
      Picker("How Hex thinks", selection: $model.setupChoice) {
        ForEach(HexInferenceSetupChoice.allCases) { choice in
          Text(choice.title)
            .tag(choice)
        }
      }
      .pickerStyle(.radioGroup)
      .disabled(model.isLoading || model.isSaving || model.isInstallingLocalModel)
      .accessibilityIdentifier("inferenceBackendPicker")
    } header: {
      Text("Choose one")
    } footer: {
      Text(model.setupChoice.detail)
    }

    switch model.setupChoice {
    case .chatGPT, .openAIAPI:
      HexOpenAIBackendSettingsView(
        model: model,
        showsAdvancedConfiguration: showsAdvancedConfiguration
      )
    case .onThisMac:
      HexMLXBackendSettingsView(
        model: model,
        showsAdvancedConfiguration: showsAdvancedConfiguration
      )
    }

    if let statusMessage = model.statusMessage {
      HexInlineNoticeView(
        message: statusMessage,
        systemImage: "info.circle",
        tint: HexBrandPalette.mutedInk
      )
    }

    if let errorMessage = model.errorMessage {
      HexInlineNoticeView(
        message: errorMessage,
        systemImage: "exclamationmark.triangle.fill",
        tint: .orange
      )
    }
    if model.needsLoadRetry {
      Button("Try Loading Again") { Task { await model.load() } }
        .disabled(model.isLoading)
    }
  }
}
