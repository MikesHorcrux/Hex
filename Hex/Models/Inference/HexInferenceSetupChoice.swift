enum HexInferenceSetupChoice: String, CaseIterable, Identifiable, Sendable {
  case chatGPT
  case openAIAPI
  case onThisMac

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chatGPT:
      "ChatGPT"
    case .openAIAPI:
      "OpenAI API key"
    case .onThisMac:
      "On this Mac"
    }
  }

  var detail: String {
    switch self {
    case .chatGPT:
      "Use your ChatGPT subscription. The simplest way to get started."
    case .openAIAPI:
      "Use metered OpenAI API billing with a key stored in Keychain."
    case .onThisMac:
      "Keep model processing on this Mac. Hex downloads the model after you continue."
    }
  }
}
