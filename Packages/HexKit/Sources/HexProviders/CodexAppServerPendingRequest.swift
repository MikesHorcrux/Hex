import HexCore

struct CodexAppServerPendingRequest: Sendable {
  let continuation: CheckedContinuation<JSONValue, any Error>
  let timeoutTask: Task<Void, Never>
  var writeCompleted = false
  var response: CodexAppServerPendingResponse?

  func resume(with response: CodexAppServerPendingResponse) {
    switch response {
    case .result(let result):
      continuation.resume(returning: result)
    case .remoteError(let code):
      continuation.resume(
        throwing: CodexAppServerConnectionError.remoteError(code: code)
      )
    }
  }
}
