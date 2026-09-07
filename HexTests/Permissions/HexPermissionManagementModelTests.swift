import Foundation
import HexCore
import HexIPC
import Testing

@testable import Hex

@Suite("Permission management presentation")
struct HexPermissionManagementModelTests {
  @Test @MainActor
  func unreachableAgentClearsOldActionableApprovalsAndFolderClaims() async throws {
    let service = Service()
    let inbox = HexApprovalInboxModel(client: PreviewHexAgentClient(), service: service)
    let folder = HexFolderAccessModel(service: service)
    await folder.refresh(ifPreviouslyRequested: true)
    #expect(await service.folderChecks == 0)
    await folder.refresh()
    #expect(folder.status?.access == .readable)
    await inbox.refresh()
    #expect(inbox.inbox?.requests.count == 1)
    await service.fail()
    await folder.refresh(ifPreviouslyRequested: true)
    await inbox.refresh()
    #expect(folder.status == nil)
    #expect(folder.message != nil)
    #expect(inbox.inbox == nil)
    #expect(inbox.message != nil)
  }

  @Test @MainActor
  func uncertainRevocationIsReadBackWithoutAutomaticResubmission() async throws {
    let service = Service()
    let model = HexApprovalInboxModel(client: PreviewHexAgentClient(), service: service)
    await model.refresh()
    let grant = try #require(model.inbox?.sessionGrants.first)
    await model.revoke(grant)
    #expect(await service.revocations == 1)
    #expect(model.inbox?.sessionGrants.isEmpty == true)
    #expect(model.message?.contains("nothing will be resubmitted automatically") == true)
    await model.refresh()
    #expect(await service.revocations == 1)
  }

  private actor Service: HexPermissionManaging {
    private var failing = false
    private(set) var folderChecks = 0
    private(set) var revocations = 0
    private let request = AuthorizationRequest(
      runID: AgentRunID(), capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read", explanation: "Read test file")
    private var grants = [
      GatewaySessionGrant(
        sessionID: UUID(), capability: CapabilityID(rawValue: "filesystem.read"),
        operation: "read", resource: "test.txt")
    ]
    func fail() { failing = true }
    func approvalInbox() throws -> GatewayApprovalInbox {
      if failing { throw GatewayFailure(code: .disconnected, message: "Disconnected") }
      return GatewayApprovalInbox(requests: [request], sessionGrants: grants)
    }
    func revokeSessionGrant(_ grant: GatewaySessionGrant) throws -> GatewayApprovalInbox {
      revocations += 1
      grants.removeAll { $0 == grant }
      throw GatewayFailure(code: .staleSession, message: "Reply lost after commit")
    }
    func folderAccessStatus() throws -> GatewayFolderAccessStatus {
      folderChecks += 1
      if failing { throw GatewayFailure(code: .disconnected, message: "Disconnected") }
      return GatewayFolderAccessStatus(
        directory: URL(fileURLWithPath: "/tmp"),
        agentBundle: URL(fileURLWithPath: "/tmp/HexGateway.app"), access: .readable)
    }
  }
}
