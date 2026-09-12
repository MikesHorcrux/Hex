import HexCore

extension OpenAIResponsesProviderError: InferenceProviderFailure {
  public var userFacingMessage: String {
    errorDescription ?? "The OpenAI Responses request failed."
  }

  public var isRetryable: Bool {
    switch self {
    case .transportFailed, .truncatedStream, .responseFailed,
      .streamFramingLimitExceeded, .streamEventLimitExceeded, .streamDeliveryLimitExceeded:
      true
    case .httpFailure(let statusCode):
      statusCode == 408 || statusCode == 409 || statusCode == 429 || statusCode >= 500
    case .invalidConfiguration, .invalidRequest, .unsupportedOutputTokenLimit, .unsupportedModel,
      .credentialUnavailable,
      .invalidContentType, .malformedStream, .streamLimitExceeded, .missingLocalContinuation,
      .localContinuationMismatch, .localStateLimitExceeded, .continuationStateLimitExceeded,
      .encryptedReasoningUnavailable:
      false
    }
  }
}
