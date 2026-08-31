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
  case encryptedReasoningUnavailable
}

extension OpenAIResponsesProviderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The OpenAI Responses provider configuration is invalid."
    case .invalidRequest:
      "The inference request is invalid for the OpenAI Responses API."
    case .unsupportedModel:
      "The requested model is not available from this provider."
    case .credentialUnavailable:
      "An OpenAI Platform API key is unavailable."
    case .transportFailed:
      "The OpenAI Responses request could not be completed."
    case .httpFailure(let statusCode):
      "The OpenAI Responses API returned HTTP status \(statusCode)."
    case .invalidContentType:
      "The OpenAI Responses API returned an unexpected content type."
    case .malformedStream:
      "The OpenAI Responses API returned a malformed event stream."
    case .streamLimitExceeded:
      "The OpenAI Responses event stream exceeded a configured safety limit."
    case .truncatedStream:
      "The OpenAI Responses event stream ended before a terminal response."
    case .responseFailed:
      "The OpenAI Responses API reported a failed response."
    case .missingLocalContinuation:
      "The local continuation state is unavailable or was evicted."
    case .localContinuationMismatch:
      "The local continuation history does not match the cached response state."
    case .localStateLimitExceeded:
      "The local continuation state exceeded a configured safety limit."
    case .encryptedReasoningUnavailable:
      "Encrypted reasoning required for local continuation was not returned."
    }
  }
}
