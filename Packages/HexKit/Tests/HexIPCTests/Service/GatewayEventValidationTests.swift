import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Gateway event validation")
struct GatewayEventValidationTests {
  @Test
  func wrongRunRecordNeverCrossesRequestedStream() async throws {
    let requestedRunID = GatewayTestValues.runID(190)
    let transport = MalformedEventGatewayTransport(
      records: [
        GatewayTestValues.record(
          runID: GatewayTestValues.runID(191),
          sequence: 1,
          event: .runStarted
        )
      ]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    await expectStreamFailure(
      client: client,
      runID: requestedRunID,
      invocationID: GatewayTestValues.invocationID(190),
      code: .wrongRun
    )
  }

  @Test
  func unsupportedSchemaRecordNeverCrossesRequestedStream() async throws {
    let runID = GatewayTestValues.runID(192)
    let transport = MalformedEventGatewayTransport(
      records: [
        GatewayTestValues.record(
          runID: runID,
          sequence: 1,
          schemaVersion: 2,
          event: .runStarted
        )
      ]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: GatewayTestValues.invocationID(192),
      code: .unsupportedEventSchema
    )
  }

  @Test(arguments: [[1, 1], [1, 3]])
  func nonContiguousSequencesNeverCrossRequestedStream(sequences: [UInt64]) async throws {
    let runID = GatewayTestValues.runID(193)
    let transport = MalformedEventGatewayTransport(
      records: sequences.map { sequence in
        GatewayTestValues.record(runID: runID, sequence: sequence, event: .runStarted)
      }
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: GatewayTestValues.invocationID(193),
      code: .invalidEventSequence
    )
  }

  @Test
  func zeroInvocationRouteIsRejectedBeforeTransportAccess() async throws {
    let runID = GatewayTestValues.runID(194)
    let transport = MalformedEventGatewayTransport(records: [])
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    let zeroUUID = UUID(
      uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    do {
      _ = try await client.eventRecords(
        for: runID,
        invocationID: GatewayRunInvocationID(rawValue: zeroUUID)
      )
      Issue.record("Expected the zero invocation route to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
    #expect(await transport.eventRequestCount == 0)
  }

  @Test
  func zeroEventIdentityNeverCrossesRequestedStream() async throws {
    let runID = GatewayTestValues.runID(195)
    let zeroUUID = UUID(
      uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
    let transport = MalformedEventGatewayTransport(
      records: [
        AgentEventRecord(
          id: AgentEventID(rawValue: zeroUUID),
          runID: runID,
          sequence: 1,
          timestamp: Date(timeIntervalSince1970: 1),
          event: .runStarted
        )
      ]
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: GatewayTestValues.invocationID(195),
      code: .malformedPayload
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
      Issue.record("Expected the malformed event stream to fail.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == code)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }
}
