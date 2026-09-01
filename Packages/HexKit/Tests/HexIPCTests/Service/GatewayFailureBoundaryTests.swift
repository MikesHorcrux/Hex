import HexCore
import HexIPC
import Testing

@Suite("Gateway failure boundary")
struct GatewayFailureBoundaryTests {
  @Test
  func canonicalizesOversizedDriverFailureBeforeLiveAndReplayExposure() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 512,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      )
    )
    let codec = GatewayWireCodec(configuration: configuration)
    let service = HexGatewayService(
      driver: OversizedFailureGatewayRunDriver(),
      configuration: configuration
    )
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(96))
    let runID = GatewayTestValues.runID(96)
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID),
      sessionID: handshake.sessionID
    )
    let invocationID = try #require(start.invocationID)

    let live = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID
    )
    let liveFailure = try #require(await terminalFailure(from: live))
    #expect(liveFailure.code == .payloadTooLarge)
    #expect(try codec.encode(liveFailure).count <= configuration.maximumWireBytes)

    let replay = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID
    )
    let replayFailure = try #require(await terminalFailure(from: replay))
    #expect(replayFailure == liveFailure)
    #expect(try codec.encode(replayFailure).count <= configuration.maximumWireBytes)
  }

  private func terminalFailure(
    from stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
  ) async -> GatewayFailure? {
    do {
      _ = try await GatewayTestValues.collect(stream)
      Issue.record("Expected the gateway stream to terminate with a failure.")
      return nil
    } catch let failure as GatewayFailure {
      return failure
    } catch {
      Issue.record("Unexpected failure type: \(error)")
      return nil
    }
  }
}
