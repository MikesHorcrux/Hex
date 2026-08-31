import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway invocation binding regressions")
struct GatewayInvocationBindingRegressionTests {
  @Test
  func eventFromPriorInvocationCannotBeReclassifiedAsCurrent() async throws {
    let runID = GatewayTestValues.runID(223)
    let priorInvocationID = GatewayTestValues.invocationID(223)
    let currentInvocationID = GatewayTestValues.invocationID(224)
    let priorRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let transport = MalformedEventGatewayTransport(
      records: [priorRecord],
      invocationID: priorInvocationID
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    try await client.acknowledge(priorRecord, invocationID: priorInvocationID)

    await expectStreamFailure(
      client: client,
      runID: runID,
      invocationID: currentInvocationID,
      code: .staleRunInvocation
    )
  }

  @Test
  func startedDispositionCannotReuseAKnownInvocationIdentity() async throws {
    let runID = GatewayTestValues.runID(225)
    let knownInvocationID = GatewayTestValues.invocationID(225)
    let knownRecord = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let transport = MalformedStartGatewayTransport(
      disposition: .started(invocationID: knownInvocationID)
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()
    try await client.acknowledge(knownRecord, invocationID: knownInvocationID)

    do {
      _ = try await client.startRun(GatewayTestValues.request(runID: runID))
      Issue.record("Expected the reused fresh-invocation identity to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleRunInvocation)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }

    #expect(
      await client.acknowledgedCursor(
        for: runID,
        invocationID: knownInvocationID
      ).sequence == 1
    )
  }

  @Test
  func startedDispositionCannotReuseInvocationLearnedFromActiveSnapshot() async throws {
    let activeRunID = GatewayTestValues.runID(233)
    let requestedRunID = GatewayTestValues.runID(234)
    let knownInvocationID = GatewayTestValues.invocationID(233)
    let transport = MalformedStartGatewayTransport(
      disposition: .started(invocationID: knownInvocationID),
      activeRun: GatewayRunSnapshot(
        runID: activeRunID,
        invocationID: knownInvocationID,
        phase: .starting,
        latestSequence: 0
      )
    )
    let client = HexGatewayClient(transport: transport)
    _ = try await client.connect()

    do {
      _ = try await client.startRun(GatewayTestValues.request(runID: requestedRunID))
      Issue.record("Expected reuse of the active snapshot invocation to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .staleRunInvocation)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }

    #expect(
      await client.acknowledgedCursor(
        for: activeRunID,
        invocationID: knownInvocationID
      ).sequence == 0
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
