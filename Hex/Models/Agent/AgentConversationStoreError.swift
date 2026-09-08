import Foundation

enum AgentConversationStoreError: Error, Equatable, LocalizedError, Sendable {
  case invalidFileURL
  case invalidMaximumBytes
  case unsafeFile
  case archiveTooLarge(actual: Int, maximum: Int)
  case malformedArchive
  case unsupportedSchemaVersion(Int)
  case invalidArchive(String)
  case ioFailure

  var errorDescription: String? {
    switch self {
    case .invalidFileURL:
      "The conversation archive path is invalid."
    case .invalidMaximumBytes:
      "The conversation archive byte limit is invalid."
    case .unsafeFile:
      "The conversation archive is not a private regular file."
    case .archiveTooLarge(let actual, let maximum):
      "The conversation archive is \(actual) bytes; the maximum is \(maximum)."
    case .malformedArchive:
      "The conversation archive is malformed or not canonical JSON."
    case .unsupportedSchemaVersion(let version):
      "The conversation archive schema version \(version) is unsupported."
    case .invalidArchive(let reason):
      "The conversation archive is invalid: \(reason)"
    case .ioFailure:
      "The conversation archive could not be read or written."
    }
  }
}
