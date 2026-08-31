import Foundation
import HexCore

/// Native Swift account boundary for Codex-managed authentication.
///
/// Hex never receives ChatGPT access or refresh tokens through this API. A concrete app-server
/// transport launches and initializes Codex, which owns credential persistence and refresh.
public actor CodexAccountClient {
  private let transport: any CodexAppServerTransport
  private let loginFlowGeneration: CodexAccountLoginFlowGenerationController
  private var state = CodexAccountClientState.idle

  public init(transport: any CodexAppServerTransport) {
    self.transport = transport
    loginFlowGeneration = transport.accountLoginFlowGeneration
  }

  public func readAccount(refreshToken: Bool = false) async throws -> CodexAccountSnapshot {
    try await ensureGenerationIsUsable()
    let result = try await send(
      CodexAppServerRequest(
        method: "account/read",
        parameters: .object(["refreshToken": .boolean(refreshToken)])
      )
    )
    return try decodeAccountSnapshot(result)
  }

  public func startLogin(_ mode: CodexChatGPTLoginMode) async throws -> CodexLoginChallenge {
    try await synchronizeStateWithGeneration()
    switch state {
    case .idle:
      state = .starting(mode)
    case .awaiting:
      throw CodexAccountClientError.loginAlreadyPending
    case .starting, .cancelling, .loggingOut:
      throw CodexAccountClientError.transitionInProgress
    }

    let reservation: UUID
    do {
      reservation = try await loginFlowGeneration.reserveLoginStart()
    } catch {
      resetStartingState(mode: mode, admittedLoginID: nil)
      throw sanitized(error)
    }

    var admittedLoginID: CodexLoginID?
    do {
      let result = try await send(
        CodexAppServerRequest(
          method: "account/login/start",
          parameters: loginParameters(for: mode)
        )
      )
      let challenge = try decodeLoginChallenge(result, expectedMode: mode)
      let earlyCompletion = try await loginFlowGeneration.issue(
        challenge.loginID,
        reservation: reservation
      )
      admittedLoginID = challenge.loginID

      guard case .starting(let activeMode) = state, activeMode == mode else {
        throw CodexAccountClientError.transitionInProgress
      }

      if earlyCompletion != nil {
        state = .idle
      } else {
        state = .awaiting(challenge.loginID)
      }
      try Task.checkCancellation()
      try await loginFlowGeneration.ensureUsable()
      return challenge
    } catch {
      if let admittedLoginID {
        await loginFlowGeneration.retire(admittedLoginID)
      } else {
        await loginFlowGeneration.abandonLoginStart(reservation)
      }
      await retireGenerationAfterAmbiguousStart()
      resetStartingState(mode: mode, admittedLoginID: admittedLoginID)
      throw sanitized(error)
    }
  }

  public func cancelLogin(
    _ loginID: CodexLoginID
  ) async throws -> CodexLoginCancellationStatus {
    try await synchronizeStateWithGeneration()
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
      try await loginFlowGeneration.beginCancellation(for: loginID)
    } catch {
      if await loginFlowGeneration.entry(for: loginID) == .completionAccepted {
        state = .idle
      } else {
        state = .awaiting(loginID)
      }
      throw sanitized(error)
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
      if completion != nil,
        await loginFlowGeneration.entry(for: loginID) != .completionAccepted
      {
        throw CodexAccountClientError.transitionInProgress
      }
      try await loginFlowGeneration.finishCancellation(for: loginID)
      state = .idle
      return status
    } catch {
      await loginFlowGeneration.abandonCancellation(for: loginID)
      if case .cancelling(let activeID, let completion) = state, activeID == loginID {
        state = completion == nil ? .awaiting(loginID) : .idle
      }
      throw sanitized(error)
    }
  }

  public func acceptLoginCompletion(_ completion: CodexLoginCompletion) async throws {
    guard let loginID = completion.loginID else {
      throw CodexAccountClientError.loginIdentifierMismatch
    }
    try await loginFlowGeneration.acceptCompletion(completion)

    switch state {
    case .awaiting(let pendingID) where pendingID == loginID:
      state = .idle
    case .cancelling(let pendingID, nil) where pendingID == loginID:
      state = .cancelling(pendingID, completion)
    case .idle, .starting, .awaiting, .cancelling, .loggingOut:
      return
    }
  }

  /// Returns the latest redacted completion only when it belongs to the requested login flow.
  public func loginCompletion(for loginID: CodexLoginID) async -> CodexLoginCompletion? {
    return await loginFlowGeneration.completion(for: loginID)
  }

  public func logout() async throws {
    try await synchronizeStateWithGeneration()
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

  /// Ends this login-flow generation after the physical transport is closed.
  ///
  /// The client remains permanently retired and deliberately retains its bounded identifier
  /// history. To continue after history exhaustion, construct a fresh transport and account client
  /// only after this method returns.
  public func retireLoginFlowGeneration() async {
    await loginFlowGeneration.retireGeneration()
    await transport.retireAccountLoginFlowGeneration()
  }

  private func ensureGenerationIsUsable() async throws {
    try await loginFlowGeneration.ensureUsable()
    switch state {
    case .idle, .starting, .awaiting, .cancelling, .loggingOut:
      return
    }
  }

  private func synchronizeStateWithGeneration() async throws {
    try await ensureGenerationIsUsable()
    if case .awaiting(let loginID) = state,
      await loginFlowGeneration.entry(for: loginID) == .completionAccepted
    {
      state = .idle
    }
  }

  private func resetStartingState(
    mode: CodexChatGPTLoginMode,
    admittedLoginID: CodexLoginID?
  ) {
    if case .starting(let activeMode) = state, activeMode == mode {
      state = .idle
    } else if case .awaiting(let activeLoginID) = state,
      activeLoginID == admittedLoginID
    {
      state = .idle
    }
  }

  private func retireGenerationAfterAmbiguousStart() async {
    await loginFlowGeneration.retireGeneration()
    await transport.retireAccountLoginFlowGeneration()
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
