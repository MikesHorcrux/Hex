import Foundation
import HexCapabilities
import HexCore
import HexIPC

/// Resident-side authorization broker. Runtime prompts remain suspended in the gateway process
/// until the interactive app returns the complete request and a choice over the authenticated XPC
/// session. Every field is compared before a waiter is removed, making replay and request-ID reuse
/// fail closed.
public actor HexGatewayAuthorizationBroker: AuthorizationPrompting {
  private var registeringRequestIDs: Set<AuthorizationRequestID> = []
  private var waiters: [AuthorizationRequestID: HexGatewayAuthorizationBrokerPendingRequest] = [:]

  public init() {}

  public func pendingRequests() -> [AuthorizationRequest] {
    waiters.values.map(\.request).sorted { $0.id.description < $1.id.description }
  }

  public func isPending(_ requestID: AuthorizationRequestID) -> Bool {
    waiters[requestID] != nil || registeringRequestIDs.contains(requestID)
  }

  public func requestDecision(
    for request: AuthorizationRequest
  ) async throws -> AuthorizationPromptResponse {
    try Task.checkCancellation()
    guard
      waiters[request.id] == nil,
      registeringRequestIDs.insert(request.id).inserted
    else {
      throw HexGatewayAuthorizationBrokerError.requestAlreadyPending
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
            continuation.resume(
              throwing: HexGatewayAuthorizationBrokerError.requestAlreadyPending)
            return
          }
          waiters[request.id] = HexGatewayAuthorizationBrokerPendingRequest(
            request: request,
            continuation: continuation
          )
        }
      },
      onCancel: {
        Task {
          await self.cancel(requestID: request.id)
        }
      }
    )
  }

  /// Applies a response exactly once. The caller should invoke this only after the XPC service has
  /// validated the connection lease and session; this actor independently validates request content.
  public func submit(
    _ request: AuthorizationRequest,
    choice: GatewayAuthorizationDecisionChoice,
    gate: HexGatewayAuthorizationCommitGate
  ) throws {
    do {
      try gate.withValidCommit {
        guard let pending = waiters[request.id] else {
          throw HexGatewayAuthorizationBrokerError.requestNotPending
        }
        guard pending.request == request else {
          throw HexGatewayAuthorizationBrokerError.requestMismatch
        }
        waiters.removeValue(forKey: request.id)
        pending.continuation.resume(returning: Self.response(for: choice))
      }
    } catch HexGatewayAuthorizationCommitGateError.closed {
      throw HexGatewayAuthorizationBrokerError.requestNotPending
    }
  }

  public func cancelAll() {
    registeringRequestIDs.removeAll()
    let pending = waiters.values
    waiters.removeAll()
    for entry in pending {
      entry.continuation.resume(throwing: CancellationError())
    }
  }

  private func cancel(requestID: AuthorizationRequestID) {
    registeringRequestIDs.remove(requestID)
    guard let pending = waiters.removeValue(forKey: requestID) else {
      return
    }
    pending.continuation.resume(throwing: CancellationError())
  }

  private static func response(
    for choice: GatewayAuthorizationDecisionChoice
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
