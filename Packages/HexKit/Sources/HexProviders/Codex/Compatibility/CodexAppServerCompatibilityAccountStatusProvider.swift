import HexCore

/// Connects to an existing Codex app-server long enough to read its redacted account state.
///
/// Hex never installs or downloads the executable. The caller supplies an already-existing
/// channel, which keeps process creation and account ownership behind the injected provider seam.
public actor CodexAppServerCompatibilityAccountStatusProvider:
  CodexCompatibilityAccountStatusProviding,
  CodexCompatibilityAccountManaging
{
  private let connection: CodexAppServerConnection
  private let accountClient: CodexAccountClient
  private var notificationHandlerInstalled = false

  private static let loginCompletionTimeout: Duration = .seconds(300)
  private static let loginCompletionPollInterval: Duration = .milliseconds(250)

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

  public func startLogin(
    _ mode: CodexChatGPTLoginMode
  ) async throws -> CodexCompatibilityLoginChallenge {
    do {
      try await installNotificationHandlerIfNeeded()
      try await connection.connect()
      let challenge = try await accountClient.startLogin(mode)
      return CodexCompatibilityLoginChallenge(challenge)
    } catch {
      await shutdown()
      throw Self.sanitized(error)
    }
  }

  public func completeLogin(_ loginID: CodexLoginID) async throws {
    do {
      try await waitForLoginCompletion(loginID)
      await shutdown()
    } catch {
      await shutdown()
      throw Self.sanitized(error)
    }
  }

  public func cancelLogin(
    _ loginID: CodexLoginID
  ) async throws -> CodexLoginCancellationStatus {
    do {
      let status = try await accountClient.cancelLogin(loginID)
      await shutdown()
      guard status == .cancelled else {
        throw CodexCompatibilityAccountManagerError.loginNotFound
      }
      return status
    } catch {
      await shutdown()
      throw Self.sanitized(error)
    }
  }

  public func logout() async throws {
    do {
      try await connection.connect()
      try await accountClient.logout()
      await shutdown()
    } catch {
      await shutdown()
      throw Self.sanitized(error)
    }
  }

  public func shutdown() async {
    await accountClient.retireLoginFlowGeneration()
  }

  private func installNotificationHandlerIfNeeded() async throws {
    guard !notificationHandlerInstalled else { return }
    try await connection.installNotificationHandler(accountClient)
    notificationHandlerInstalled = true
  }

  private func waitForLoginCompletion(_ loginID: CodexLoginID) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: Self.loginCompletionTimeout)
    while clock.now < deadline {
      try Task.checkCancellation()
      if let completion = await accountClient.loginCompletion(for: loginID) {
        guard completion.succeeded else {
          throw CodexCompatibilityAccountManagerError.loginRejected
        }
        return
      }
      try await Task.sleep(for: Self.loginCompletionPollInterval)
    }
    throw CodexCompatibilityAccountManagerError.loginTimedOut
  }

  private static func sanitized(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled {
      return CancellationError()
    }
    if let error = error as? CodexAccountClientError {
      return error
    }
    if let error = error as? CodexCompatibilityAccountManagerError {
      return error
    }
    return CodexCompatibilityAccountManagerError.failed
  }
}
