public enum MCPManagedToolExecutorState: String, Equatable, Sendable {
  case disconnected
  case connecting
  case ready
  case unavailable
}
