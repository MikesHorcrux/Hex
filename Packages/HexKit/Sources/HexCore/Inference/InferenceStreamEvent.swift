public enum InferenceStreamEvent: Codable, Equatable, Sendable {
  case started(providerResponseID: String?)
  case textDelta(String)
  case reasoningSummaryDelta(String)
  /// A complete tool call. Partial provider arguments must be assembled before this event is sent.
  case toolCall(ToolCall)
  case usage(InferenceUsage)
  case completed(InferenceStopReason)
}
