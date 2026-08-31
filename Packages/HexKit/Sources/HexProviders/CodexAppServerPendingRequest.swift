import HexCore

struct CodexAppServerPendingRequest: Sendable {
  let continuation: CheckedContinuation<JSONValue, any Error>
  let timeoutTask: Task<Void, Never>
}
