import Foundation

/// Public, deliberately redacted failures from the OpenAI Responses provider.
public enum OpenAIResponsesProviderError: Error, Equatable, Sendable {
  public enum StreamFramingLimit: Equatable, Sendable {
    case unspecified
    case responseBytes
    case lineBytes
    case eventBytes
    case eventCount
  }

  case invalidConfiguration
  case invalidRequest
  case unsupportedOutputTokenLimit
  case unsupportedModel
  case credentialUnavailable
  case transportFailed
  case httpFailure(statusCode: Int)
  case invalidContentType(receivedMediaType: String?)
  case malformedStream
  case streamLimitExceeded
  case streamFramingLimitExceeded(StreamFramingLimit)
  case streamEventLimitExceeded
  case streamDeliveryLimitExceeded
  case truncatedStream
  case responseFailed
  case missingLocalContinuation
  case localContinuationMismatch
  case localStateLimitExceeded
  case continuationStateLimitExceeded
  case encryptedReasoningUnavailable
}
