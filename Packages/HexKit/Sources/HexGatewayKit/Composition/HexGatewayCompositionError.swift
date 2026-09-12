import Foundation

public enum HexGatewayCompositionError: Error, Equatable, LocalizedError, Sendable {
  case duplicateEmitter
  case invalidRecord(String)
  case missingJournal
  case inferenceUnavailable
  case toolUnavailable
  case invalidPersonalityConfiguration

  public var errorDescription: String? {
    switch self {
    case .duplicateEmitter:
      "An event emitter is already installed for the run."
    case .invalidRecord(let message):
      message
    case .missingJournal:
      "A durable event journal is required to open the gateway."
    case .inferenceUnavailable:
      "No inference provider is configured for this gateway."
    case .toolUnavailable:
      "No tool executor is configured for this gateway."
    case .invalidPersonalityConfiguration:
      "The gateway personality context dependencies are incomplete."
    }
  }
}
