import HexCore

/// Injected request boundary for an initialized Codex app-server connection.
///
/// The concrete connection owns JSON-RPC identifiers, framing, response-size limits, and process
/// lifetime. Account credentials remain owned by Codex; this boundary exchanges only protocol
/// requests and their decoded result values.
public protocol CodexAppServerTransport: Sendable {
  func send(_ request: CodexAppServerRequest) async throws -> JSONValue
}
