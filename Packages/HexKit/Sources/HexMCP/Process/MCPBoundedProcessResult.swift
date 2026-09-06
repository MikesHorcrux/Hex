import Foundation

/// The bounded output and normalized exit status from one local process invocation.
public struct MCPBoundedProcessResult: Sendable {
  public let status: Int32
  public let standardOutput: Data
  public let standardError: Data
}
