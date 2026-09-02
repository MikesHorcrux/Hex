import HexCore
import SwiftUI

struct HexOpenAIBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Section {
      Picker("Authentication", selection: $model.openAIAuthenticationMethod) {
        ForEach(HexOpenAIAuthenticationMethod.allCases) { method in
          Text(method.displayName).tag(method)
        }
      }
      .accessibilityIdentifier("inferenceOpenAIAuthenticationPicker")

      switch model.openAIAuthenticationMethod {
      case .chatGPT:
        HexChatGPTAuthenticationSettingsView(model: model)
      case .apiKey:
        SecureField("OpenAI API key", text: $model.openAIAPIKey)
          .textContentType(.password)
          .accessibilityIdentifier("inferenceOpenAIAPIKeyField")

        Text(
          model.hasStoredOpenAIAPIKey
            ? "A key is stored in Keychain. Leave this blank to keep it."
            : "The key is stored only in Keychain; it is never written to settings or UserDefaults."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      TextField("Model identifier", text: $model.openAIModelID)
        .accessibilityIdentifier("inferenceOpenAIModelField")
    } header: {
      Text("OpenAI inference")
    } footer: {
      Text(
        "Hex owns the agent loop, tools, approvals, and memory. Authentication only selects whether inference uses your ChatGPT/Codex subscription or OpenAI API billing. The subscription route is an experimental compatibility integration, not a published third-party OpenAI API."
      )
    }
  }
}
