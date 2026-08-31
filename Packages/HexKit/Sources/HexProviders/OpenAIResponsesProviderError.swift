import Foundation

/// Public, deliberately redacted failures from the OpenAI Responses provider.
public enum OpenAIResponsesProviderError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidRequest
  case unsupportedModel
  case credentialUnavailable
  case transportFailed
  case httpFailure(statusCode: Int)
  case invalidContentType
  case malformedStream
  case streamLimitExceeded
  case truncatedStream
  case responseFailed
  case missingLocalContinuation
  case localContinuationMismatch
  case localStateLimitExceeded
  case continuationStateLimitExceeded
  case encryptedReasoningUnavailable
}
