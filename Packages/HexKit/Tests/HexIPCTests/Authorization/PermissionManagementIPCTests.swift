import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Authenticated permission management IPC")
struct PermissionManagementIPCTests {
  @Test
  func sessionAndBodyValidationPrecedePermissionDispatch() async throws {
    let calls = Calls()
    let grant = GatewaySessionGrant(
      sessionID: UUID(), capability: CapabilityID(rawValue: "filesystem.read"),
      operation: "read", resource: "example.txt")
    let inbox = GatewayApprovalInbox(sessionGrants: [grant], defaultMode: .approveForMe)
    let folder = GatewayFolderAccessStatus(
      directory: URL(fileURLWithPath: "/tmp"),
      agentBundle: URL(fileURLWithPath: "/tmp/HexGateway.app"), access: .denied)
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      permissionManagementHandlers: HexGatewayPermissionManagementHandlers(
        inbox: {
          await calls.record()
          return inbox
        },
        revoke: { received in
          #expect(received == grant)
          await calls.record()
          return GatewayApprovalInbox()
        },
        folder: {
          await calls.record()
          return folder
        }), toolServerControlHandlers: .unavailable)
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease()
    let handshake = try await send(
      GatewayXPCRequestEnvelope(
        operation: .handshake, lease: lease,
        body: codec.encode(GatewayTestValues.handshakeRequest())), to: service, codec: codec)
    let session = try codec.decode(GatewayHandshakeResponse.self, from: #require(handshake.body))
      .sessionID
    for operation in [GatewayXPCOperation.approvalInbox, .revokeSessionGrant, .folderAccessStatus] {
      let body = operation == .revokeSessionGrant ? try codec.encode(grant) : Data()
      let stale = try await send(
        GatewayXPCRequestEnvelope(
          operation: operation, lease: lease,
          sessionID: GatewaySessionID(), body: body), to: service, codec: codec)
      #expect(stale.failure?.code == .staleSession)
    }
    #expect(await calls.count == 0)
    let malformed = try await send(
      GatewayXPCRequestEnvelope(
        operation: .approvalInbox, lease: lease,
        sessionID: session, body: Data("{}".utf8)), to: service, codec: codec)
    #expect(malformed.failure?.code == .malformedPayload)
    #expect(await calls.count == 0)
    let inboxResponse = try await send(
      GatewayXPCRequestEnvelope(
        operation: .approvalInbox, lease: lease,
        sessionID: session, body: Data()), to: service, codec: codec)
    #expect(
      try codec.decode(GatewayApprovalInbox.self, from: #require(inboxResponse.body)) == inbox)
    let folderResponse = try await send(
      GatewayXPCRequestEnvelope(
        operation: .folderAccessStatus, lease: lease,
        sessionID: session, body: Data()), to: service, codec: codec)
    #expect(
      try codec.decode(GatewayFolderAccessStatus.self, from: #require(folderResponse.body))
        == folder)
    let revoked = try await send(
      GatewayXPCRequestEnvelope(
        operation: .revokeSessionGrant, lease: lease,
        sessionID: session, body: codec.encode(grant)), to: service, codec: codec)
    #expect(
      try codec.decode(GatewayApprovalInbox.self, from: #require(revoked.body)).sessionGrants
        .isEmpty)
    #expect(await calls.count == 3)
    service.invalidate()
  }

  private actor Calls {
    private(set) var count = 0
    func record() { count += 1 }
  }

  private func send(
    _ envelope: GatewayXPCRequestEnvelope, to service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayXPCResponseEnvelope {
    let encoded = try codec.encode(envelope)
    let data: Data = await withCheckedContinuation { continuation in
      service.request(encoded) { continuation.resume(returning: $0) }
    }
    return try codec.decode(GatewayXPCResponseEnvelope.self, from: data).validated()
  }
}
