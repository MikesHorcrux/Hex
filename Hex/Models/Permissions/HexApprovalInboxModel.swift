import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class HexApprovalInboxModel {
  private(set) var inbox: GatewayApprovalInbox?
  private(set) var isBusy = false
  var message: String? { refreshError ?? decisionNotice }
  private var refreshError: String?
  private var decisionNotice: String?
  private let service: (any HexPermissionManaging)?
  private let client: any HexAgentClient

  init(client: any HexAgentClient, service: (any HexPermissionManaging)? = nil) {
    self.client = client
    self.service = service ?? (client as? any HexPermissionManaging)
  }

  func refresh() async {
    guard !isBusy else { return }
    isBusy = true
    defer { isBusy = false }
    do {
      guard let service else {
        throw GatewayFailure(
          code: .transportUnavailable,
          message: "The approval inbox requires the resident Hex Agent.")
      }
      let response = try await service.approvalInbox().validated()
      try Task.checkCancellation()
      inbox = response
      refreshError = nil
    } catch {
      // Never leave stale actionable rows on screen after losing the resident connection.
      inbox = nil
      if !(error is CancellationError) { refreshError = error.localizedDescription }
    }
  }

  func decide(_ request: AuthorizationRequest, choice: AuthorizationDecisionChoice) async {
    guard !isBusy, inbox?.requests.contains(request) == true else { return }
    await mutate {
      try await client.decideAuthorization(request, choice: choice)
    }
  }

  func revoke(_ grant: GatewaySessionGrant) async {
    guard !isBusy, let service, inbox?.sessionGrants.contains(grant) == true else { return }
    await mutate { _ = try await service.revokeSessionGrant(grant) }
  }

  private func mutate(_ operation: () async throws -> Void) async {
    isBusy = true
    decisionNotice = nil
    do {
      try await operation()
      decisionNotice = "Decision saved."
    } catch {
      decisionNotice =
        "The response could not be confirmed. Rechecking the agent; nothing will be resubmitted automatically. \(error.localizedDescription)"
    }
    inbox = nil
    isBusy = false
    await refresh()
  }
}
