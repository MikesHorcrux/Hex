import HexCore

/// A single initialized Codex app-server JSON-RPC request before envelope framing.
public struct CodexAppServerRequest: Equatable, Sendable {
  public let method: String
  public let parameters: JSONValue
}
