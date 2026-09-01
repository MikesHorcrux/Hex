import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway sequence boundary regressions")
struct GatewaySequenceBoundaryRegressionTests {
  @Test
  func maximumCursorIsRejectedBeforeTransportAccess() async throws {
    let runID = GatewayTestValues.runID(231)
    let invocationID = GatewayTestValues.invocationID(231)
    let transport = MalformedEventGatewayTransport(records: [])
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    await client.installSequence(
      UInt64.max,
      runID: runID,
      invocationID: invocationID
    )

    do {
      _ = try await client.eventRecords(for: runID, invocationID: invocationID)
      Issue.record("Expected the maximum cursor to reject advancement.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .invalidCursor)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
    #expect(await transport.eventRequestCount == 0)
  }

  @Test
  func sequenceAfterMaximumNeverCrossesTheClientBoundary() async throws {
    let runID = GatewayTestValues.runID(232)
    let invocationID = GatewayTestValues.invocationID(232)
    let transport = MalformedEventGatewayTransport(
      records: [
        GatewayTestValues.record(
          runID: runID,
          sequence: UInt64.max,
          event: .messageAppended(GatewayTestValues.request(runID: runID).initialMessages[0])
        ),
        GatewayTestValues.record(runID: runID, sequence: 0, event: .runCompleted),
      ]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    await client.installSequence(
      UInt64.max - 1,
      runID: runID,
      invocationID: invocationID
    )

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: invocationID,
      code: .invalidEventSequence
    )
  }

  private func expectStreamFailure(
    client: HexGatewayClient,
    runID: AgentRunID,
    invocationID: GatewayRunInvocationID,
    code: GatewayFailureCode
  ) async {
    do {
      let stream = try await client.eventRecords(for: runID, invocationID: invocationID)
      _ = try await GatewayTestValues.collect(stream)
      Issue.record("Expected the hostile event stream to fail with \(code).")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }
}
