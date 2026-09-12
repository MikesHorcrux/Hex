/// A host tool rejected model arguments before authorization or dispatch, including a definitely
/// absent executable reference. Never use for permission, transport, or execution errors.
public struct ToolCallValidationError: Error, Sendable {
  public let recovery: String

  public init(recovery: String) {
    self.recovery = recovery
  }
}
