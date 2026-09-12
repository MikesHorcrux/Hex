/// A host-recorded reason an announced tool was never dispatched. This is not a tool's own claim
/// about side effects; absence on an older result says nothing about whether that action executed.
public enum ToolNonExecutionReason: String, Codable, Equatable, Sendable {
  case cancelled
  case runStopped
  case interrupted
  case authorizationDenied
  case invalidArguments
}
