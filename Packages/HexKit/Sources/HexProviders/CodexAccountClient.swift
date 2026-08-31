import HexCore

/// Native Swift account boundary for Codex-managed authentication.
///
/// Hex never receives ChatGPT access or refresh tokens through this API. A concrete app-server
/// transport launches and initializes Codex, which owns credential persistence and refresh.
public actor CodexAccountClient {
  private let transport: any CodexAppServerTransport
  private var state = CodexAccountClientState.idle
  private var latestLoginCompletion: CodexLoginCompletion?
  private var loginFlowLedger: CodexAccountLoginFlowLedger

  public init(transport: any CodexAppServerTransport) {
    self.transport = transport
    loginFlowLedger = CodexAccountLoginFlowLedger()
  }

  init?(
    transport: any CodexAppServerTransport,
    loginFlowHistoryCapacity: Int
  ) {
    guard (1...64).contains(loginFlowHistoryCapacity) else {
      return nil
    }
    self.transport = transport
    loginFlowLedger = CodexAccountLoginFlowLedger(
      validatedCapacity: loginFlowHistoryCapacity
    )
  }

  public func readAccount(refreshToken: Bool = false) async throws -> CodexAccountSnapshot {
    try ensureGenerationIsUsable()
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
      guard loginFlowLedger.hasCapacity else {
        throw CodexAccountClientError.loginFlowHistoryExhausted
      }
      state = .starting(mode, nil)
      latestLoginCompletion = nil
    case .awaiting:
      throw CodexAccountClientError.loginAlreadyPending
    case .starting, .cancelling, .loggingOut, .retiringGeneration:
      throw CodexAccountClientError.transitionInProgress
    case .retiredGeneration:
      throw CodexAccountClientError.loginFlowGenerationRetired
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
      try loginFlowLedger.issue(challenge.loginID)

      if let earlyCompletion {
        guard earlyCompletion.loginID == challenge.loginID else {
          loginFlowLedger.retire(challenge.loginID)
          state = .idle
          latestLoginCompletion = nil
          throw CodexAccountClientError.loginIdentifierMismatch
        }
        try loginFlowLedger.acceptCompletion(for: challenge.loginID)
        latestLoginCompletion = earlyCompletion
        state = .idle
      } else {
        state = .awaiting(challenge.loginID)
      }
      return challenge
    } catch {
      if case .starting(let activeMode, let earlyCompletion) = state, activeMode == mode {
        state = .idle
        if earlyCompletion != nil {
          latestLoginCompletion = nil
        }
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
    case .starting, .cancelling, .loggingOut, .retiringGeneration:
      throw CodexAccountClientError.transitionInProgress
    case .retiredGeneration:
      throw CodexAccountClientError.loginFlowGenerationRetired
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
      if completion == nil {
        loginFlowLedger.retire(loginID)
      } else {
        guard loginFlowLedger.entry(for: loginID) == .completionAccepted else {
          throw CodexAccountClientError.transitionInProgress
        }
      }
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

    if state == .retiredGeneration {
      throw CodexAccountClientError.loginFlowGenerationRetired
    }

    switch loginFlowLedger.entry(for: loginID) {
    case .retiredAwaitingCompletion:
      try loginFlowLedger.acceptCompletion(for: loginID)
      latestLoginCompletion = completion
    case .completionAccepted:
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .pending:
      try acceptPendingCompletion(completion, loginID: loginID)
    case .none:
      try acceptUnboundCompletion(completion)
    }
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
    case .starting, .cancelling, .loggingOut, .retiringGeneration:
      throw CodexAccountClientError.transitionInProgress
    case .retiredGeneration:
      throw CodexAccountClientError.loginFlowGenerationRetired
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

  /// Ends this login-flow generation after the physical transport is closed.
  ///
  /// The client remains permanently retired and deliberately retains its bounded identifier
  /// history. To continue after history exhaustion, construct a fresh transport and account client
  /// only after this method returns.
  public func retireLoginFlowGeneration() async {
    guard state != .retiredGeneration else { return }
    state = .retiringGeneration
    await transport.retireAccountLoginFlowGeneration()
    state = .retiredGeneration
  }

  private func acceptPendingCompletion(
    _ completion: CodexLoginCompletion,
    loginID: CodexLoginID
  ) throws {
    switch state {
    case .awaiting(let pendingID) where pendingID == loginID:
      try loginFlowLedger.acceptCompletion(for: loginID)
      state = .idle
      latestLoginCompletion = completion
    case .cancelling(let pendingID, nil) where pendingID == loginID:
      try loginFlowLedger.acceptCompletion(for: loginID)
      state = .cancelling(pendingID, completion)
      latestLoginCompletion = completion
    case .retiringGeneration:
      try loginFlowLedger.acceptCompletion(for: loginID)
      latestLoginCompletion = completion
    case .awaiting, .cancelling:
      throw CodexAccountClientError.loginIdentifierMismatch
    case .idle, .starting, .loggingOut:
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .retiredGeneration:
      throw CodexAccountClientError.loginFlowGenerationRetired
    }
  }

  private func acceptUnboundCompletion(_ completion: CodexLoginCompletion) throws {
    switch state {
    case .starting(let mode, nil):
      state = .starting(mode, completion)
      latestLoginCompletion = completion
    case .starting:
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .idle where loginFlowLedger.isEmpty:
      throw CodexAccountClientError.unexpectedLoginCompletion
    case .retiredGeneration:
      throw CodexAccountClientError.loginFlowGenerationRetired
    case .idle, .awaiting, .cancelling, .loggingOut, .retiringGeneration:
      throw CodexAccountClientError.loginIdentifierMismatch
    }
  }

  private func ensureGenerationIsUsable() throws {
    switch state {
    case .retiringGeneration:
      throw CodexAccountClientError.transitionInProgress
    case .retiredGeneration:
      throw CodexAccountClientError.loginFlowGenerationRetired
    case .idle, .starting, .awaiting, .cancelling, .loggingOut:
      return
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
