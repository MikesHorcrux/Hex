import Foundation

public enum JSONPersonalMemoryStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidFileURL
  case invalidConfiguration
  case malformedStore
  case recordsTooLarge
  case unsafeFile
  case lockFailure
  case encodingFailure
  case ioFailure

  public var errorDescription: String? {
    switch self {
    case .invalidFileURL:
      "The personal memory file URL is invalid."
    case .invalidConfiguration:
      "The personal memory store limits are invalid."
    case .malformedStore:
      "The personal memory store contains malformed or unsupported durable data."
    case .recordsTooLarge:
      "The personal memory store exceeds its configured bounds."
    case .unsafeFile:
      "The personal memory path is not a private file owned by the current user."
    case .lockFailure:
      "The personal memory lock could not be acquired."
    case .encodingFailure:
      "The personal memory store could not be encoded."
    case .ioFailure:
      "The personal memory store could not be read or durably written."
    }
  }
}
