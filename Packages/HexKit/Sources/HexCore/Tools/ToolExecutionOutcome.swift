/// Host-adapter evidence. A known command failure is distinct from an unknown dispatch outcome.
public enum ToolExecutionOutcome: String, Codable, Sendable {
  case completed
}
