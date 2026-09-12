import Darwin
import Dispatch
import Foundation

struct MCPBoundedProcessRunnerDrainResult: Sendable {
  let reachedEndOfFile: Bool
  let exceededLimit: Bool
}
