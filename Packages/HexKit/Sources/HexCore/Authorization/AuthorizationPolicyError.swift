/// Explicit user policy must not be silently discarded by a custom authorization provider.
public enum AuthorizationPolicyError: Error, Equatable, Sendable {
  case unsupportedOverride
  case runPolicyAlreadyEstablished
}
