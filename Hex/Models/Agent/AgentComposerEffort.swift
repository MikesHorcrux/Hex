import HexCore

nonisolated enum AgentComposerEffort: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case none
  case minimal
  case low
  case medium
  case high
  case extraHigh
  case max
  case ultra
  case persistent

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .automatic:
      "Automatic"
    case .none:
      "None"
    case .minimal:
      "Minimal"
    case .low:
      "Low"
    case .medium:
      "Medium"
    case .high:
      "High"
    case .extraHigh:
      "Extra high"
    case .max:
      "Max"
    case .ultra:
      "Ultra"
    case .persistent:
      "Persistent"
    }
  }

  var inferenceValue: InferenceReasoningEffort? {
    switch self {
    case .automatic:
      nil
    case .none:
      InferenceReasoningEffort.none
    case .minimal:
      .minimal
    case .low:
      .low
    case .medium:
      .medium
    case .high:
      .high
    case .extraHigh:
      .xhigh
    case .max:
      .max
    case .ultra:
      .ultra
    case .persistent:
      .persistent
    }
  }

  init(_ value: InferenceReasoningEffort) {
    self = value == .xhigh ? .extraHigh : Self(rawValue: value.rawValue) ?? .automatic
  }
}
