import HexCore

/// Run-owned evidence, not a retry queue. Only calls that have never reached a durable-start
/// attempt may receive a host-authored nonexecution receipt when the run stops.
struct AgentToolDispatchLedger: Sendable {
  private enum State: Equatable, Sendable {
    case neverStarted
    case startAttempted
    case receiptAttempted
    case settled
  }

  private var calls: [ToolCall] = []
  private var states: [ToolCallID: State] = [:]

  var neverStartedCalls: [ToolCall] {
    calls.filter { states[$0.id] == .neverStarted }
  }

  mutating func announce(_ announcedCalls: [ToolCall]) throws {
    var identities = Set(states.keys)
    guard announcedCalls.allSatisfy({ identities.insert($0.id).inserted }) else {
      throw AgentRuntimeError.invalidState("A native tool call was announced more than once.")
    }
    for call in announcedCalls {
      calls.append(call)
      states[call.id] = .neverStarted
    }
  }

  mutating func markStartAttempted(_ callID: ToolCallID) throws {
    guard states[callID] == .neverStarted else {
      throw AgentRuntimeError.invalidState("A tool start has no unique pending native call.")
    }
    states[callID] = .startAttempted
  }

  mutating func markReceiptAttempted(_ callID: ToolCallID) throws {
    guard let state = states[callID], state == .neverStarted || state == .startAttempted else {
      throw AgentRuntimeError.invalidState("A native tool receipt has no unique pending call.")
    }
    states[callID] = .receiptAttempted
  }

  mutating func markSettled(_ callID: ToolCallID) throws {
    guard states[callID] == .receiptAttempted else {
      throw AgentRuntimeError.invalidState(
        "A native tool receipt was settled without its durable pair.")
    }
    states[callID] = .settled
  }
}
