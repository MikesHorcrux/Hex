import Foundation
import HexCapabilities
import HexCore
import HexIPC
import Testing

@testable import HexGatewayKit

@Suite("Resident approval inbox and revocation")
struct HexGatewayPermissionManagerTests {
  @Test
  func pendingRequestSurvivesReadersAndSessionGrantCanBeRevoked() async throws {
    let broker = HexGatewayAuthorizationBroker()
    let center = CapabilityAuthorizationCenter(prompter: broker)
    let manager = HexGatewayPermissionManager(
      broker: broker, center: center, defaultMode: .askEveryTime,
      folderProbe: HexGatewayFolderAccessProbe(
        directory: URL(fileURLWithPath: "/tmp"),
        agentBundle: URL(fileURLWithPath: "/tmp/HexGateway.app"), read: { _ in .readable }))
    let request = AuthorizationRequest(
      runID: AgentRunID(), capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read", resource: "file:example.txt", explanation: "Read the chosen file.")
    let decision = Task { try await center.authorize(request) }
    defer { decision.cancel() }
    for _ in 0..<200 {
      if await broker.isPending(request.id) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await manager.inbox().requests == [request])
    #expect(try await manager.inbox().requests == [request])
    try await broker.submit(
      request, choice: .allowForSession, gate: HexGatewayAuthorizationCommitGate())
    #expect(try await decision.value == .allow)
    let after = try await manager.inbox()
    #expect(after.requests.isEmpty)
    let grant = try #require(after.sessionGrants.first)
    #expect(grant.resource == request.resource)
    let oldGrant = GatewaySessionGrant(
      sessionID: UUID(), capability: grant.capability,
      operation: grant.operation, resource: grant.resource)
    await #expect(throws: GatewayFailure.self) { try await manager.revoke(oldGrant) }
    #expect(try await manager.inbox().sessionGrants == [grant])
    #expect(try await manager.revoke(grant).sessionGrants.isEmpty)
    let next = Task { try await center.authorize(request) }
    defer { next.cancel() }
    for _ in 0..<200 {
      if await broker.isPending(request.id) { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try await manager.inbox().requests == [request])
    await broker.cancelAll()
    await #expect(throws: CancellationError.self) { try await next.value }
    #expect(try await manager.inbox().requests.isEmpty)
    await #expect(throws: HexGatewayAuthorizationBrokerError.self) {
      try await broker.submit(
        request, choice: .allowOnce, gate: HexGatewayAuthorizationCommitGate())
    }
  }

  @Test
  func folderProbeChecksAnActualDirectoryAndKeepsDenialDistinctFromMissing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let agent = directory.appendingPathComponent("HexGateway.app")
    let readable = try HexGatewayFolderAccessProbe(directory: directory, agentBundle: agent).check()
    #expect(readable.access == .readable)
    #expect(readable.directory == directory)
    #expect(readable.agentBundle == agent)
    let missing = try HexGatewayFolderAccessProbe(
      directory: directory.appendingPathComponent("missing"), agentBundle: agent
    ).check()
    #expect(missing.access == .unavailable)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    #expect(
      try HexGatewayFolderAccessProbe(directory: directory, agentBundle: agent).check().access
        == .denied)
  }

  @Test
  func duplicateRequestsAndUnboundedScopesAreRejected() throws {
    let request = AuthorizationRequest(
      runID: AgentRunID(), capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read", explanation: "Read")
    #expect(throws: GatewayFailure.self) {
      try GatewayApprovalInbox(requests: [request, request]).validated()
    }
    let invalid = GatewaySessionGrant(
      sessionID: UUID(), capability: request.capability,
      operation: "read", resource: String(repeating: "x", count: 16_385))
    #expect(throws: GatewayFailure.self) {
      try GatewayApprovalInbox(sessionGrants: [invalid]).validated()
    }
  }
}
