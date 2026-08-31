import Foundation

public struct ProcessExecutionResult: Equatable, Sendable {
  public let termination: ProcessTermination
  public let output: Data
  public let durationMilliseconds: UInt64

  public init(
    termination: ProcessTermination,
    output: Data,
    durationMilliseconds: UInt64
  ) {
    self.termination = termination
    self.output = output
    self.durationMilliseconds = durationMilliseconds
  }
}
