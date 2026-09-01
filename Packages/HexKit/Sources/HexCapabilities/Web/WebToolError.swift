public enum WebToolError: Error, Equatable, Sendable {
  case invalidArguments
  case authorizationRequired
  case authorizationStateUnavailable
  case urlNotAllowed
  case hostResolutionFailed
  case privateAddressRejected
  case networkFailure
  case invalidResponse
  case unsupportedContentType
  case invalidTextEncoding
  case searchResponseInvalid
  case openURLFailed
}
