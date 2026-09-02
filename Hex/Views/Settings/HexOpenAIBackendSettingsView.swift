import SwiftUI

struct HexOpenAIBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel

  var body: some View {
    Section {
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

      TextField("Model identifier", text: $model.openAIModelID)
        .accessibilityIdentifier("inferenceOpenAIModelField")
    } header: {
      Text("OpenAI Responses API")
    } footer: {
      Text("This uses OpenAI Platform API-key inference through the Responses endpoint.")
    }
  }
}
