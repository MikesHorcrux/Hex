import HexCore

struct AgentComposerModelOption: Equatable, Identifiable, Sendable {
  let id: ModelID
  let displayName: String
  let supportedEfforts: [AgentComposerEffort]

  init(modelID: String) {
    id = ModelID(rawValue: modelID)
    displayName = Self.friendlyDisplayName(for: modelID)
    supportedEfforts = [.automatic]
  }

  init(descriptor: ModelDescriptor) {
    id = descriptor.id
    displayName =
      descriptor.displayName == descriptor.id.rawValue
      ? Self.friendlyDisplayName(for: descriptor.id.rawValue) : descriptor.displayName
    supportedEfforts =
      [.automatic] + (descriptor.supportedReasoningEfforts ?? []).map(AgentComposerEffort.init)
  }

  private static func friendlyDisplayName(for modelID: String) -> String {
    switch modelID.lowercased() {
    case "preview":
      "Preview"
    case "gpt-5.6-luna":
      "GPT-5.6 Luna"
    case "gpt-5.6-terra":
      "GPT-5.6 Terra"
    case "gpt-5.6-sol":
      "GPT-5.6 Sol"
    case "gpt-5.5":
      "GPT-5.5"
    case "gpt-5.4":
      "GPT-5.4"
    case "gpt-5.4-mini":
      "GPT-5.4 Mini"
    case "gpt-5.3-codex-spark":
      "GPT-5.3 Spark"
    case "mlx-community/qwen3-4b-4bit":
      "Qwen 3 4B"
    default:
      "Configured model"
    }
  }
}
