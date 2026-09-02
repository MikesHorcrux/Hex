import HexCore

/// Connects to an existing Codex app-server long enough to read its redacted account state.
///
/// Hex never installs or downloads the executable. The caller supplies an already-existing
/// channel, which keeps process creation and account ownership behind the injected provider seam.
public actor CodexAppServerCompatibilityAccountStatusProvider:
  CodexCompatibilityAccountStatusProviding
{
  private let connection: CodexAppServerConnection
  private let accountClient: CodexAccountClient

  public init(
    configuration: CodexAppServerConnectionConfiguration,
    channel: any CodexAppServerChannel
  ) {
    let connection = CodexAppServerConnection(configuration: configuration, channel: channel)
    self.connection = connection
    accountClient = CodexAccountClient(transport: connection)
  }

  public func status() async -> CodexCompatibilityAccountStatus {
    do {
      try await connection.connect()
      let snapshot = try await accountClient.readAccount(refreshToken: false)
      await connection.disconnect()
      return CodexCompatibilityAccountStatus(snapshot: snapshot)
    } catch is CancellationError {
      await connection.disconnect()
      return .unavailable
    } catch {
      await connection.disconnect()
      return .unavailable
    }
  }
}
