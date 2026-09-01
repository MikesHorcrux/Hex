import Foundation
import HexCapabilities
import HexCore

/// Bridges the runtime's authorization prompt to the main-actor UI through an actor-owned waiter.
/// The runtime remains paused until the operator submits a matching decision.
actor HexAuthorizationBroker: AuthorizationPrompting {
  enum BrokerError: Error, Equatable, LocalizedError, Sendable {
    case requestNotPending
    case requestAlreadyPending

    var errorDescription: String? {
      switch self {
      case .requestNotPending:
        "That authorization request is no longer pending. Reconnect and try again."
      case .requestAlreadyPending:
        "That authorization request is already pending. Answer the existing request first."
      }
    }
  }

  private var registeringRequestIDs: Set<AuthorizationRequestID> = []
  private var waiters:
    [AuthorizationRequestID: CheckedContinuation<AuthorizationPromptResponse, any Error>] = [:]

  func requestDecision(
    for request: AuthorizationRequest
  ) async throws -> AuthorizationPromptResponse {
    try Task.checkCancellation()
    guard
      waiters[request.id] == nil,
      registeringRequestIDs.insert(request.id).inserted
    else {
      throw BrokerError.requestAlreadyPending
    }

    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          registeringRequestIDs.remove(request.id)
          guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          guard waiters[request.id] == nil else {
            continuation.resume(throwing: BrokerError.requestAlreadyPending)
            return
          }
          waiters[request.id] = continuation
        }
      },
      onCancel: {
        Task {
          await self.cancel(requestID: request.id)
        }
      })
  }

  func submit(
    _ request: AuthorizationRequest,
    choice: AuthorizationDecisionChoice
  ) throws {
    guard let waiter = waiters.removeValue(forKey: request.id) else {
      throw BrokerError.requestNotPending
    }
    waiter.resume(returning: Self.response(for: choice))
  }

  private func cancel(requestID: AuthorizationRequestID) {
    registeringRequestIDs.remove(requestID)
    guard let waiter = waiters.removeValue(forKey: requestID) else {
      return
    }
    waiter.resume(throwing: CancellationError())
  }

  private static func response(
    for choice: AuthorizationDecisionChoice
  ) -> AuthorizationPromptResponse {
    switch choice {
    case .allowOnce:
      .allow(scope: .once)
    case .allowForSession:
      .allow(scope: .session)
    case .deny:
      .deny(reason: "Denied by the operator.")
    }
  }
}
