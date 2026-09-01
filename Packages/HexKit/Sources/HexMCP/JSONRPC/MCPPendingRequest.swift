import HexCore

struct MCPPendingRequest: Sendable {
  let continuation: CheckedContinuation<JSONValue, any Error>
  let timeoutTask: Task<Void, Never>
}
