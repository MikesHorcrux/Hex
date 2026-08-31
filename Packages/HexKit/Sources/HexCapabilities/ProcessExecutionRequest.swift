import Foundation

public struct ProcessExecutionRequest: Equatable, Sendable {
  public let executable: URL
  public let arguments: [String]
  public let workingDirectory: URL
  public let timeoutSeconds: Int

  public init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: Int
  ) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.timeoutSeconds = timeoutSeconds
  }
}
