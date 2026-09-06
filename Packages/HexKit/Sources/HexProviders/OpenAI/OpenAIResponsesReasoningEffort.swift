public enum OpenAIResponsesReasoningEffort: String, Codable, CaseIterable, Sendable {
  case none
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max
  case ultra
  case persistent
}
