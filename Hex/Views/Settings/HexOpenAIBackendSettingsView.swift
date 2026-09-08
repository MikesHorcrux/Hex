import HexCore
import SwiftUI

struct HexOpenAIBackendSettingsView: View {
  @Bindable var model: HexInferenceBackendSettingsModel
  let showsAdvancedConfiguration: Bool

  var body: some View {
    Section {
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

      if showsAdvancedConfiguration {
        DisclosureGroup("Advanced") {
          TextField("Model identifier", text: $model.openAIModelID)
            .accessibilityIdentifier("inferenceOpenAIModelField")
        }
      }
    } header: {
      Text(model.openAIAuthenticationMethod == .chatGPT ? "ChatGPT" : "OpenAI API")
    } footer: {
      Text(footerText)
    }
    .disabled(model.isSaving || model.isLoading)
  }

  private var footerText: String {
    switch model.openAIAuthenticationMethod {
    case .chatGPT:
      "Sign in once, then Hex can use your ChatGPT subscription for answers."
    case .apiKey:
      "Your key stays in Keychain. OpenAI API usage is billed separately from ChatGPT."
    }
  }
}
