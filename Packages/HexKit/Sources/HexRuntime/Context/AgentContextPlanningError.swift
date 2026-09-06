/// Planner failures contain no conversation text, tool arguments, or provider credentials.
public enum AgentContextPlanningError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidModelMetadata
  case invalidOutputReserve
  case invalidHistory
  case invalidEstimate
  case arithmeticOverflow
  case unserializableContent
  case imageCostUnavailable
}
