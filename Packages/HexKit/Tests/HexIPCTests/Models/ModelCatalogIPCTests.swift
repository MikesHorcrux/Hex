import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Model catalog IPC")
struct ModelCatalogIPCTests {
  @Test
  func catalogRequiresAuthenticatedSessionAndPreservesEffortMetadata() async throws {
    let calls = CallCount()
    let model = ModelDescriptor(
      id: ModelID(rawValue: "test-model"),
      providerID: ProviderID(rawValue: "test"), displayName: "Test model",
      capabilities: [.textInput], supportedReasoningEfforts: [.low, .ultra],
      defaultReasoningEffort: .low)
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver()),
      modelCatalogHandler: {
        await calls.record()
        return [model]
      }
    )
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease()
    let disconnected = try await request(
      GatewayXPCRequestEnvelope(
        operation: .availableModels, lease: lease, sessionID: GatewaySessionID(), body: Data()
      ), service: service, codec: codec)
    #expect(disconnected.failure?.code == .notConnected)
    #expect(await calls.value == 0)

    let handshake = try await request(
      GatewayXPCRequestEnvelope(
        operation: .handshake, lease: lease,
        body: try codec.encode(GatewayTestValues.handshakeRequest())
      ), service: service, codec: codec)
    let session = try codec.decode(
      GatewayHandshakeResponse.self,
      from: try #require(handshake.body)
    ).sessionID
    let result = try await request(
      GatewayXPCRequestEnvelope(
        operation: .availableModels, lease: lease, sessionID: session, body: Data()
      ), service: service, codec: codec)
    #expect(try codec.decode([ModelDescriptor].self, from: try #require(result.body)) == [model])
    #expect(await calls.value == 1)

    let malformed = try await request(
      GatewayXPCRequestEnvelope(
        operation: .availableModels, lease: lease, sessionID: session, body: Data("{}".utf8)
      ), service: service, codec: codec)
    #expect(malformed.failure?.code == .malformedPayload)
    #expect(await calls.value == 1)
  }

  private actor CallCount {
    var value = 0
    func record() { value += 1 }
  }

  private func request(
    _ envelope: GatewayXPCRequestEnvelope, service: HexGatewayXPCService,
    codec: GatewayWireCodec
  ) async throws -> GatewayXPCResponseEnvelope {
    let data = try codec.encode(envelope)
    let result = await withCheckedContinuation { continuation in
      service.request(data) { continuation.resume(returning: $0) }
    }
    return try codec.decode(GatewayXPCResponseEnvelope.self, from: result).validated()
  }
}
