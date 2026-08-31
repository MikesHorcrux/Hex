public enum InferenceStopReason: Codable, Equatable, Sendable {
  case stop
  case toolCalls
  case length
  case contentFilter
  case other(String)
}
