import HexCore

/// Injected request boundary for an initialized Codex app-server connection.
///
/// The concrete connection owns JSON-RPC identifiers, framing, response-size limits, and process
/// lifetime. Account credentials remain owned by Codex; this boundary exchanges only protocol
/// requests and their decoded result values.
public protocol CodexAppServerTransport: Sendable {
  /// The one login-flow generation controller owned by this transport instance.
  var accountLoginFlowGeneration: CodexAccountLoginFlowGenerationController { get }

  func send(_ request: CodexAppServerRequest) async throws -> JSONValue

  /// Permanently ends the account-login generation represented by this transport instance.
  ///
  /// Implementations must make this operation idempotent and return only after the physical
  /// transport no longer accepts I/O. Implementations must mark `accountLoginFlowGeneration`
  /// retired before awaiting physical close. The instance must not then back a fresh account
  /// client; callers regain bounded login capacity by constructing a new transport and client.
  func retireAccountLoginFlowGeneration() async
}
