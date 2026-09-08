/// Optional provider-route metadata. A false value means `maxOutputTokens` cannot be enforced
/// by that inference service; callers must not pretend an omitted server option is a server cap.
/// Legacy providers retain their existing request-option behavior unless they adopt this contract.
public protocol InferenceOutputLimitReporting: Sendable {
  var supportsServerOutputTokenLimit: Bool { get }
}
