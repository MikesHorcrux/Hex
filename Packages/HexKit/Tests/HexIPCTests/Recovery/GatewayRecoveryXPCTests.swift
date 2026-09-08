import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Recovery XPC endpoint")
struct GatewayRecoveryXPCTests {
  @Test
  func recoveryRequiresTheCurrentSessionAndPreservesOriginalRecords() async throws {
    let runID = GatewayTestValues.runID(176)
    let reader = Reader(runID: runID)
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayXPCService(
      service: HexGatewayService(driver: driver, historyReader: reader))
    let codec = GatewayWireCodec(configuration: .standard)
    let lease = GatewayTransportConnectionLease()
    let query = GatewayRunRecoveryRequest(runID: runID)
    let disconnected = try await request(
      GatewayXPCRequestEnvelope(
        operation: .recoverRun, lease: lease, sessionID: GatewaySessionID(),
        body: codec.encode(query)), service: service, codec: codec)
    #expect(disconnected.failure?.code == .notConnected)
    #expect(await reader.reads == 0)
    let hello = try await request(
      GatewayXPCRequestEnvelope(
        operation: .handshake, lease: lease,
        body: codec.encode(GatewayTestValues.handshakeRequest())), service: service, codec: codec)
    let handshake = try codec.decode(GatewayHandshakeResponse.self, from: #require(hello.body))
    let response = try await request(
      GatewayXPCRequestEnvelope(
        operation: .recoverRun, lease: lease, sessionID: handshake.sessionID,
        body: codec.encode(query)), service: service, codec: codec)
    let recovered = try codec.decode(GatewayRunRecoveryResponse.self, from: #require(response.body))
    guard case .journaled(let snapshot) = recovered.disposition else {
      Issue.record("Expected journaled recovery.")
      return
    }
    let pageRequest = GatewayRunHistoryRequest(
      runID: runID, firstEventID: snapshot.firstEventID, afterSequence: 0,
      throughSequence: snapshot.latestSequence)
    let history = try await request(
      GatewayXPCRequestEnvelope(
        operation: .readRunHistory, lease: lease, sessionID: handshake.sessionID,
        body: codec.encode(pageRequest)), service: service, codec: codec)
    let page = try codec.decode(GatewayRunHistoryPage.self, from: #require(history.body))
    #expect(page.gatewayInstanceID == handshake.gatewayInstanceID)
    #expect(page.records == reader.stored)
    #expect(await driver.invocationCount(for: runID) == 0)
  }

  private actor Reader: HexGatewayRunHistoryReading {
    nonisolated let stored: [AgentEventRecord]
    var reads = 0
    init(runID: AgentRunID) {
      stored = [
        GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted),
        GatewayTestValues.record(runID: runID, sequence: 2, event: .runCancelled),
      ]
    }
    func snapshot(for runID: AgentRunID) async throws -> GatewayJournalRunSnapshot? {
      reads += 1
      return GatewayJournalRunSnapshot(
        runID: runID, firstEventID: stored[0].id, latestSequence: 2, terminalRecord: stored[1])
    }
    func records(
      for runID: AgentRunID, after: UInt64, through: UInt64, limit: Int, maximumBytes: Int
    ) async throws -> [AgentEventRecord] {
      Array(stored.filter { $0.sequence > after && $0.sequence <= through }.prefix(limit))
    }
  }

  private func request(
    _ envelope: GatewayXPCRequestEnvelope, service: HexGatewayXPCService, codec: GatewayWireCodec
  ) async throws -> GatewayXPCResponseEnvelope {
    let data = try codec.encode(envelope)
    let result = await withCheckedContinuation { continuation in
      service.request(data) { continuation.resume(returning: $0) }
    }
    return try codec.decode(GatewayXPCResponseEnvelope.self, from: result).validated()
  }
}
