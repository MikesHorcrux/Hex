import Foundation

extension OpenAIResponsesProviderError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The OpenAI Responses provider configuration is invalid."
    case .invalidRequest:
      "The inference request is invalid for the OpenAI Responses API."
    case .unsupportedOutputTokenLimit:
      "The ChatGPT / Codex connection does not support a server output-token limit. Please remove the explicit output limit or use the OpenAI API connection."
    case .unsupportedModel:
      "The requested model is not available from this provider."
    case .credentialUnavailable:
      "OpenAI authorization is unavailable."
    case .transportFailed:
      "The OpenAI Responses request could not be completed."
    case .httpFailure(let statusCode):
      "The OpenAI Responses API returned HTTP status \(statusCode)."
    case .invalidContentType(let receivedMediaType):
      if let receivedMediaType {
        "The OpenAI Responses API returned \(receivedMediaType) instead of an event stream."
      } else {
        "The OpenAI Responses API response did not identify an event-stream content type."
      }
    case .malformedStream:
      "The OpenAI Responses API returned a malformed event stream."
    case .streamLimitExceeded:
      "The OpenAI Responses event stream exceeded a configured safety limit."
    case .streamFramingLimitExceeded(let limit):
      switch limit {
      case .unspecified:
        "The OpenAI Responses byte stream exceeded a configured framing safety limit."
      case .responseBytes:
        "The OpenAI Responses byte stream exceeded the total response safety limit."
      case .lineBytes:
        "The OpenAI Responses byte stream contained a line over the safety limit."
      case .eventBytes:
        "The OpenAI Responses byte stream contained an event over the safety limit."
      case .eventCount:
        "The OpenAI Responses byte stream exceeded the event-count safety limit."
      }
    case .streamEventLimitExceeded:
      "An OpenAI Responses event exceeded a configured processing safety limit."
    case .streamDeliveryLimitExceeded:
      "The OpenAI Responses event consumer could not keep up with the stream."
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
    case .continuationStateLimitExceeded:
      "The OpenAI continuation state exceeded a configured safety limit."
    case .encryptedReasoningUnavailable:
      "Encrypted reasoning required for local continuation was not returned."
    }
  }
}
