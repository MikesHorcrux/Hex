import Foundation
import HexCore

/// Native Swift account boundary for Codex-managed authentication.
///
/// Hex never receives ChatGPT access or refresh tokens through this API. A concrete app-server
/// transport launches and initializes Codex, which owns credential persistence and refresh.
public actor CodexAccountClient {
  private let transport: any CodexAppServerTransport
  private let loginFlowGeneration: CodexAccountLoginFlowGenerationController
  private let ownerID: UUID

  public init(transport: any CodexAppServerTransport) {
    self.transport = transport
    loginFlowGeneration = transport.accountLoginFlowGeneration
    ownerID = UUID()
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
    let reservation: UUID
    do {
      reservation = try await loginFlowGeneration.reserveLoginStart(owner: ownerID)
    } catch {
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
      _ = try await loginFlowGeneration.issue(
        challenge.loginID,
        reservation: reservation
      )
      admittedLoginID = challenge.loginID

      try Task.checkCancellation()
      try await loginFlowGeneration.ensureUsable()
      return challenge
    } catch {
      await loginFlowGeneration.retireAfterAmbiguousStart(
        reservation: reservation,
        admittedLoginID: admittedLoginID
      )
      await transport.retireAccountLoginFlowGeneration()
      throw sanitized(error)
    }
  }

  public func cancelLogin(
    _ loginID: CodexLoginID
  ) async throws -> CodexLoginCancellationStatus {
    do {
      try await loginFlowGeneration.beginCancellation(for: loginID, owner: ownerID)
    } catch {
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
      try await loginFlowGeneration.finishCancellation(for: loginID, owner: ownerID)
      return status
    } catch {
      await loginFlowGeneration.abandonCancellation(for: loginID, owner: ownerID)
      throw sanitized(error)
    }
  }

  public func acceptLoginCompletion(_ completion: CodexLoginCompletion) async throws {
    guard completion.loginID != nil else {
      throw CodexAccountClientError.loginIdentifierMismatch
    }
    try await loginFlowGeneration.acceptCompletion(completion)
  }

  /// Returns the latest redacted completion only when it belongs to the requested login flow.
  public func loginCompletion(for loginID: CodexLoginID) async -> CodexLoginCompletion? {
    return await loginFlowGeneration.completion(for: loginID)
  }

  public func logout() async throws {
    let reservation: UUID
    do {
      reservation = try await loginFlowGeneration.reserveLogout(owner: ownerID)
    } catch {
      throw sanitized(error)
    }

    do {
      let result = try await send(
        CodexAppServerRequest(method: "account/logout", parameters: .null)
      )
      try Task.checkCancellation()
      guard result == .object([:]) else {
        throw CodexAccountClientError.malformedResponse
      }
      try await loginFlowGeneration.finishLogout(for: reservation, owner: ownerID)
    } catch {
      await loginFlowGeneration.abandonLogout(reservation, owner: ownerID)
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
