/// A host tool's pure argument validation rejected the call before authorization or dispatch.
/// Throw only for malformed model arguments, never for permission, transport, or execution errors.
public struct ToolCallValidationError: Error, Sendable {
  public let recovery: String

  public init(recovery: String) {
    self.recovery = recovery
  }
}
