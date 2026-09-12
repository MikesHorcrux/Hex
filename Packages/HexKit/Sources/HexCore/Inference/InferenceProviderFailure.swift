/// An inference-provider error whose message is deliberately safe to persist and show to the user.
/// Provider errors do not cross the runtime boundary unless they opt into this contract.
public protocol InferenceProviderFailure: Error, Sendable {
  var userFacingMessage: String { get }
  var isRetryable: Bool { get }
}
