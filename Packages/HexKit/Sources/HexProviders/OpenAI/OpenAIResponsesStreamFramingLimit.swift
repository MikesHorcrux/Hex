import Foundation

public enum OpenAIResponsesStreamFramingLimit: Equatable, Sendable {
  case unspecified
  case responseBytes
  case lineBytes
  case eventBytes
  case eventCount
}
