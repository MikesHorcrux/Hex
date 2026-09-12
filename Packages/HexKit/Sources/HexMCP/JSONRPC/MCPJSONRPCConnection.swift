import HexCore

protocol MCPJSONRPCConnection: Sendable {
  func connect() async throws

  func disconnect() async

  func request(method: String, params: JSONValue) async throws -> JSONValue

  func notify(method: String, params: JSONValue?) async throws
}
