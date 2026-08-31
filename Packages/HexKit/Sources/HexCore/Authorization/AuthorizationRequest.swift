/// Structured policy input. Request details must describe the operation without containing secrets.
public struct AuthorizationRequest: Identifiable, Codable, Equatable, Sendable {
  public let id: AuthorizationRequestID
  public let runID: AgentRunID
  public let toolCallID: ToolCallID?
  public let capability: CapabilityID
  public let operation: String
  public let resource: String?
  public let details: [String: JSONValue]
  public let explanation: String

  public init(
    id: AuthorizationRequestID = AuthorizationRequestID(),
    runID: AgentRunID,
    toolCallID: ToolCallID? = nil,
    capability: CapabilityID,
    operation: String,
    resource: String? = nil,
    details: [String: JSONValue] = [:],
    explanation: String
  ) {
    self.id = id
    self.runID = runID
    self.toolCallID = toolCallID
    self.capability = capability
    self.operation = operation
    self.resource = resource
    self.details = details
    self.explanation = explanation
  }
}
