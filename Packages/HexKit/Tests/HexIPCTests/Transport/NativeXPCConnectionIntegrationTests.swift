@preconcurrency import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Native XPC connection integration")
struct NativeXPCConnectionIntegrationTests {
  @Test
  func exportedServiceHandlesHandshakeAcrossFoundationXPC() async throws {
    let exportedService = HexGatewayXPCService(
      service: HexGatewayService(driver: ImmediateGatewayRunDriver())
    )
    let protocolService: any HexGatewayXPCServiceProtocol = exportedService
    _ = protocolService

    let listenerDelegate = HexGatewayXPCListenerDelegate(
      serviceFactory: { exportedService }
    )
    let listener = NSXPCListener.anonymous()
    listener.delegate = listenerDelegate
    listener.resume()
    defer {
      listener.invalidate()
    }

    let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
    connection.remoteObjectInterface = HexGatewayXPCService.interface()
    connection.activate()
    defer {
      connection.invalidate()
    }

    let codec = GatewayWireCodec(configuration: .standard)
    let request = GatewayTestValues.handshakeRequest(231)
    let envelope = try codec.encode(
      GatewayXPCRequestEnvelope(
        operation: .handshake,
        lease: GatewayTransportConnectionLease(rawValue: GatewayTestValues.uuid(232)),
        body: try codec.encode(request)
      )
    )

    let responseData = try await send(envelope, over: connection)
    let response = try codec.decode(GatewayXPCResponseEnvelope.self, from: responseData).validated()
    #expect(response.operation == .handshake)
    #expect(response.failure == nil)
    let handshake = try codec.decode(
      GatewayHandshakeResponse.self,
      from: try #require(response.body)
    )
    #expect(handshake.selectedVersion == .current)
  }

  private func send(
    _ envelope: Data,
    over connection: NSXPCConnection
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          continuation.resume(throwing: error)
        }) as? HexGatewayXPCServiceProtocol
      else {
        continuation.resume(
          throwing: GatewayFailure(
            code: .transportUnavailable,
            message: "The native XPC proxy could not be created."
          )
        )
        return
      }
      proxy.request(envelope) { response in
        continuation.resume(returning: response)
      }
    }
  }
}
