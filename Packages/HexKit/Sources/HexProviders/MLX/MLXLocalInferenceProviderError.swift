public enum MLXLocalInferenceProviderError: Error, Equatable, Sendable {
  case invalidModelConfiguration
  case invalidProviderConfiguration
  case wrongProvider
  case unknownModel
  case unsupportedContinuation
  case invalidRequest
  case invalidToolChoice
  case busy
  case modelLoadFailed
  case generationFailed
  case invalidStream
  case incompleteStream
  case parallelToolCallsUnsupported
  case consumerTooSlow
}
