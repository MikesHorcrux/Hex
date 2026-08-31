/// Durable facts emitted by an agent run. A cancelled run journals `runCancelled`, never
/// `runFailed`; Swift `CancellationError` is never wrapped as `AgentFailure`.
public enum AgentEvent: Codable, Equatable, Sendable {
  case runStarted
  case messageAppended(Message)
  case inferenceRequested(InferenceRequest)
  case inferenceEvent(InferenceStreamEvent)
  case authorizationRequested(AuthorizationRequest)
  case authorizationDecided(
    requestID: AuthorizationRequestID,
    decision: AuthorizationDecision
  )
  case toolStarted(ToolCall)
  case toolFinished(ToolResult)
  case runCompleted
  case runCancelled
  case runFailed(AgentFailure)
}
