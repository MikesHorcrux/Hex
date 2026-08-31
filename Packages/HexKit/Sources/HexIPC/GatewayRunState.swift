import Foundation
import HexCore

struct GatewayRunState: Sendable {
  let request: GatewayStartRunRequest
  var phase: GatewayRunPhase
  var latestSequence: UInt64
  var retainedRecords: [AgentEventRecord]
  var terminalSequence: UInt64?
  var completionFailure: GatewayFailure?
  var subscribers: [UUID: GatewaySubscriber]
  var task: Task<Void, Never>?

  init(request: GatewayStartRunRequest) {
    self.request = request
    phase = .starting
    latestSequence = 0
    retainedRecords = []
    terminalSequence = nil
    completionFailure = nil
    subscribers = [:]
    task = nil
  }
}
