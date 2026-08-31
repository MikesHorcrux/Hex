import HexIPC
import Testing

@Suite("Gateway run-state installation")
struct GatewayImmediateEmissionTests {
  @Test
  func installsRunStateBeforeNewDriverCanEmit() async throws {
    let service = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let transport = InProcessHexGatewayTransport(service: service)
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest())
    let runID = GatewayTestValues.runID()

    let start = try await transport.startRun(GatewayTestValues.request(runID: runID))
    let invocationID = try #require(start.invocationID)
    let stream = try await transport.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID)
    )
    let records = try await GatewayTestValues.collect(stream)

    #expect(records.map(\.sequence) == [1, 2])
    #expect(records.map(\.event) == [.runStarted, .runCompleted])
  }
}
