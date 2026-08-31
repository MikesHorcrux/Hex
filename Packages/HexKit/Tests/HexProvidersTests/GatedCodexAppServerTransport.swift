import HexCore

@testable import HexProviders

actor GatedCodexAppServerTransport: CodexAppServerTransport {
  private var request: CodexAppServerRequest?
  private var requestWaiter: CheckedContinuation<Void, Never>?
  private var responseWaiter: CheckedContinuation<JSONValue, any Error>?

  func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    self.request = request
    requestWaiter?.resume()
    requestWaiter = nil
    return try await withCheckedThrowingContinuation { continuation in
      responseWaiter = continuation
    }
  }

  func waitForRequest() async {
    guard request == nil else {
      return
    }
    await withCheckedContinuation { continuation in
      requestWaiter = continuation
    }
  }

  func succeed(with value: JSONValue) {
    responseWaiter?.resume(returning: value)
    responseWaiter = nil
  }
}
