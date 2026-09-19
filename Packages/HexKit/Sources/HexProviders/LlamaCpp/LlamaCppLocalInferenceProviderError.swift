import Foundation

public enum LlamaCppLocalInferenceProviderError: Error, Equatable, LocalizedError, Sendable {
  case invalidProviderConfiguration
  case invalidModelConfiguration
  case invalidRequest
  case unsupportedContinuation
  case busy
  case transportFailed
  case httpFailure(Int)
  case invalidResponse
  case invalidStream

  public var errorDescription: String? {
    switch self {
    case .invalidProviderConfiguration:
      "The local llama.cpp provider configuration is invalid."
    case .invalidModelConfiguration:
      "The local llama.cpp model configuration is invalid."
    case .invalidRequest:
      "The local llama.cpp provider rejected the inference request."
    case .unsupportedContinuation:
      "The local llama.cpp provider does not support server-managed continuation."
    case .busy:
      "The local llama.cpp provider is already handling a request."
    case .transportFailed:
      "Hex could not reach the local llama.cpp server. Start Prism llama-server and try again."
    case .httpFailure(let statusCode):
      "The local llama.cpp server returned HTTP \(statusCode)."
    case .invalidResponse:
      "The local llama.cpp server returned an invalid response."
    case .invalidStream:
      "The local llama.cpp server returned an invalid event stream."
    }
  }
}
