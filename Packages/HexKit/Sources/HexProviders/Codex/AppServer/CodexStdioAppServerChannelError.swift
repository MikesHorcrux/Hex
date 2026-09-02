import Foundation

/// Secret-free failures from the concrete Codex app-server stdio channel.
public enum CodexStdioAppServerChannelError: Error, Equatable, LocalizedError, Sendable {
  case invalidConfiguration
  case alreadyOpen
  case closed
  case executableUnavailable
  case unsafeExecutable
  case workingDirectoryUnavailable
  case spawnFailed
  case ioFailure
  case outputLimitExceeded

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "The Codex app-server channel configuration is invalid."
    case .alreadyOpen:
      "The Codex app-server channel is already open."
    case .closed:
      "The Codex app-server channel is closed."
    case .executableUnavailable:
      "The configured Codex executable is unavailable."
    case .unsafeExecutable:
      "The configured Codex executable is not safe to launch."
    case .workingDirectoryUnavailable:
      "The Codex app-server working directory is unavailable."
    case .spawnFailed:
      "The Codex app-server process could not be started."
    case .ioFailure:
      "The Codex app-server stdio channel failed."
    case .outputLimitExceeded:
      "The Codex app-server output exceeded the channel limit."
    }
  }
}
