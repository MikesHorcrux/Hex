import HexCore

/// Native Swift account boundary for Codex-managed authentication.
///
/// Hex never receives ChatGPT access or refresh tokens through this API. A concrete app-server
/// transport launches and initializes Codex, which owns credential persistence and refresh.
public actor CodexAccountClient {
  private let transport: any CodexAppServerTransport
  private var state = CodexAccountClientState.idle
  private var latestLoginCompletion: CodexLoginCompletion?
  private var cancelledLoginCompletionID: CodexLoginID?
  private var hasAcceptedCancelledLoginCompletion = false

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
      latestLoginCompletion = nil
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
          latestLoginCompletion = nil
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
      state = .cancelling(loginID, nil)
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
      guard case .cancelling(let activeID, let completion) = state, activeID == loginID else {
        throw CodexAccountClientError.transitionInProgress
      }
      cancelledLoginCompletionID = loginID
      hasAcceptedCancelledLoginCompletion = completion != nil
      state = .idle
      return status
    } catch {
      if case .cancelling(let activeID, let completion) = state, activeID == loginID {
        state = completion == nil ? .awaiting(loginID) : .idle
      }
      throw sanitized(error)
    }
  }

  public func acceptLoginCompletion(_ completion: CodexLoginCompletion) throws {
    guard let loginID = completion.loginID else {
      throw CodexAccountClientError.loginIdentifierMismatch
    }

    switch state {
    case .starting(let mode, let earlyCompletion):
      if cancelledLoginCompletionID == loginID {
        guard !hasAcceptedCancelledLoginCompletion else {
          throw CodexAccountClientError.unexpectedLoginCompletion
        }
        hasAcceptedCancelledLoginCompletion = true
      } else if earlyCompletion == nil {
        state = .starting(mode, completion)
      } else {
        throw CodexAccountClientError.unexpectedLoginCompletion
      }
    case .awaiting(let pendingID):
      if pendingID == loginID {
        state = .idle
      } else if cancelledLoginCompletionID == loginID {
        guard !hasAcceptedCancelledLoginCompletion else {
          throw CodexAccountClientError.unexpectedLoginCompletion
        }
        hasAcceptedCancelledLoginCompletion = true
      } else {
        throw CodexAccountClientError.loginIdentifierMismatch
      }
    case .cancelling(let pendingID, let cancellationCompletion):
      if pendingID == loginID, cancellationCompletion == nil {
        state = .cancelling(pendingID, completion)
      } else if pendingID == loginID {
        throw CodexAccountClientError.unexpectedLoginCompletion
      } else if cancelledLoginCompletionID == loginID {
        guard !hasAcceptedCancelledLoginCompletion else {
          throw CodexAccountClientError.unexpectedLoginCompletion
        }
        hasAcceptedCancelledLoginCompletion = true
      } else {
        throw CodexAccountClientError.loginIdentifierMismatch
      }
    case .idle, .loggingOut:
      if cancelledLoginCompletionID == loginID {
        guard !hasAcceptedCancelledLoginCompletion else {
          throw CodexAccountClientError.unexpectedLoginCompletion
        }
        hasAcceptedCancelledLoginCompletion = true
      } else if cancelledLoginCompletionID == nil {
        throw CodexAccountClientError.unexpectedLoginCompletion
      } else {
        throw CodexAccountClientError.loginIdentifierMismatch
      }
    }
    latestLoginCompletion = completion
  }

  /// Returns the latest redacted completion only when it belongs to the requested login flow.
  public func loginCompletion(for loginID: CodexLoginID) -> CodexLoginCompletion? {
    guard latestLoginCompletion?.loginID == loginID else {
      return nil
    }
    return latestLoginCompletion
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
