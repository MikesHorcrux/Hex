import HexCore

/// Native Swift account boundary for Codex-managed authentication.
///
/// Hex never receives ChatGPT access or refresh tokens through this API. A concrete app-server
/// transport launches and initializes Codex, which owns credential persistence and refresh.
public actor CodexAccountClient {
  private let transport: any CodexAppServerTransport
  private var state = CodexAccountClientState.idle

  public init(transport: any CodexAppServerTransport) {
    self.transport = transport
  }

  public func readAccount(refreshToken: Bool = false) async throws -> CodexAccountSnapshot {
    let result = try await send(
      CodexAppServerRequest(
        method: "account/read",
        parameters: .object(["refreshToken": .boolean(refreshToken)])
      )
    )
    return try decodeAccountSnapshot(result)
  }

  public func startLogin(_ mode: CodexChatGPTLoginMode) async throws -> CodexLoginChallenge {
    switch state {
    case .idle:
      state = .starting(mode, nil)
    case .awaiting:
      throw CodexAccountClientError.loginAlreadyPending
    case .starting, .cancelling, .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }

    do {
      let result = try await send(
        CodexAppServerRequest(
          method: "account/login/start",
          parameters: loginParameters(for: mode)
        )
      )
      try Task.checkCancellation()
      let challenge = try decodeLoginChallenge(result, expectedMode: mode)

      guard case .starting(let activeMode, let earlyCompletion) = state,
        activeMode == mode
      else {
        throw CodexAccountClientError.transitionInProgress
      }

      if let earlyCompletion {
        guard earlyCompletion.loginID == challenge.loginID else {
          state = .idle
          throw CodexAccountClientError.loginIdentifierMismatch
        }
        state = .idle
      } else {
        state = .awaiting(challenge.loginID)
      }
      return challenge
    } catch {
      if case .starting(let activeMode, _) = state, activeMode == mode {
        state = .idle
      }
      throw sanitized(error)
    }
  }

  public func cancelLogin(
    _ loginID: CodexLoginID
  ) async throws -> CodexLoginCancellationStatus {
    switch state {
    case .awaiting(let pendingID) where pendingID == loginID:
      state = .cancelling(loginID)
    case .awaiting:
      throw CodexAccountClientError.loginIdentifierMismatch
    case .idle:
      throw CodexAccountClientError.noPendingLogin
    case .starting, .cancelling, .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }

    do {
      let result = try await send(
        CodexAppServerRequest(
          method: "account/login/cancel",
          parameters: .object(["loginId": .string(loginID.rawValue)])
        )
      )
      try Task.checkCancellation()
      let status = try decodeCancellationStatus(result)
      if case .cancelling(let activeID) = state, activeID == loginID {
        state = .idle
      }
      return status
    } catch {
      if case .cancelling(let activeID) = state, activeID == loginID {
        state = .awaiting(loginID)
      }
      throw sanitized(error)
    }
  }

  public func acceptLoginCompletion(_ completion: CodexLoginCompletion) throws {
    guard let loginID = completion.loginID else {
      throw CodexAccountClientError.loginIdentifierMismatch
    }

    switch state {
    case .starting(let mode, nil):
      state = .starting(mode, completion)
    case .starting(_, .some):
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .awaiting(let pendingID), .cancelling(let pendingID):
      guard pendingID == loginID else {
        throw CodexAccountClientError.loginIdentifierMismatch
      }
      state = .idle
    case .idle, .loggingOut:
      throw CodexAccountClientError.unexpectedLoginCompletion
    }
  }

  public func logout() async throws {
    switch state {
    case .idle:
      state = .loggingOut
    case .awaiting:
      throw CodexAccountClientError.loginAlreadyPending
    case .starting, .cancelling, .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }

    do {
      let result = try await send(
        CodexAppServerRequest(method: "account/logout", parameters: .null)
      )
      try Task.checkCancellation()
      guard result == .object([:]) else {
        throw CodexAccountClientError.malformedResponse
      }
      state = .idle
    } catch {
      if state == .loggingOut {
        state = .idle
      }
      throw sanitized(error)
    }
  }

  private func send(_ request: CodexAppServerRequest) async throws -> JSONValue {
    do {
      return try await transport.send(request)
    } catch {
      throw sanitized(error)
    }
  }

  private func sanitized(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled {
      return CancellationError()
    }
    if let error = error as? CodexAccountClientError {
      return error
    }
    return CodexAccountClientError.transportFailure
  }
}
