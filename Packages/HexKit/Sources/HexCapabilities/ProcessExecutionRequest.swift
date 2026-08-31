import Foundation

public struct ProcessExecutionRequest: Equatable, Sendable {
  /// An executable path passed directly to `posix_spawn`; arguments are never shell-interpolated.
  public let executable: URL
  public let arguments: [String]
  public let workingDirectory: URL
  /// The complete environment passed to the child. An omitted environment is intentionally empty;
  /// execution never observes ambient-environment changes after request construction.
  public let environment: [String: String]
  public let timeoutSeconds: Int

  public init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String]? = nil,
    timeoutSeconds: Int
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment ?? [:]
    self.timeoutSeconds = timeoutSeconds
  }
}
