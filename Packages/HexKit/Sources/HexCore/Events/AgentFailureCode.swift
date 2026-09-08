public enum AgentFailureCode: String, Codable, CaseIterable, Sendable {
  case invalidRequest = "invalid_request"
  case unsupportedCapability = "unsupported_capability"
  case authentication
  case transport
  case provider
  case authorization
  case toolExecution = "tool_execution"
  case journal
  case invalidState = "invalid_state"
}
