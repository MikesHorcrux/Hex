import Foundation
import HexCore
import Testing

@testable import HexIPC

@Suite("Gateway service identity regressions")
struct GatewayServiceIdentityRegressionTests {
  @Test
  func serviceRejectsZeroEventIdentityBeforeReplayMutation() async throws {
    let runID = GatewayTestValues.runID(229)
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(229))
    let start = try await service.startRun(
      GatewayTestValues.request(runID: runID),
      sessionID: handshake.sessionID
    )
    let invocationID = try #require(start.invocationID)
    await driver.waitUntilStarted(runID)
    let stream = try await service.eventRecords(
      after: GatewayEventCursor(runID: runID, invocationID: invocationID),
      sessionID: handshake.sessionID
    )
    let zeroUUID = UUID(
      uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
    await driver.yieldAndWait(
      AgentEventRecord(
        id: AgentEventID(rawValue: zeroUUID),
        runID: runID,
        sequence: 1,
        timestamp: Date(timeIntervalSince1970: 1),
        event: .runStarted
      )
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await driver.finish(runID)

    do {
      _ = try await GatewayTestValues.collect(stream)
      Issue.record("Expected the zero event identity to fail at service admission.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }

  @Test
  func serviceRejectsZeroRunIdentityBeforeAdmission() async throws {
    let zeroUUID = zeroUUID()
    let service = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(230))

    do {
      _ = try await service.startRun(
        GatewayTestValues.request(runID: AgentRunID(rawValue: zeroUUID)),
        sessionID: handshake.sessionID
      )
      Issue.record("Expected the zero run identity to fail at service admission.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }

  @Test
  func serviceRejectsZeroRunIdentityBeforeCancellationLookup() async throws {
    let service = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(235))

    do {
      _ = try await service.cancelRun(
        GatewayCancelRunRequest(
          runID: AgentRunID(rawValue: zeroUUID()),
          invocationID: GatewayTestValues.invocationID(235)
        ),
        sessionID: handshake.sessionID
      )
      Issue.record("Expected the zero cancellation run identity to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }

  @Test
  func serviceRejectsZeroRunIdentityBeforeReplayLookup() async throws {
    let service = HexGatewayService(driver: ImmediateGatewayRunDriver())
    let handshake = try await service.handshake(GatewayTestValues.handshakeRequest(236))

    do {
      _ = try await service.eventRecords(
        after: GatewayEventCursor(
          runID: AgentRunID(rawValue: zeroUUID()),
          invocationID: GatewayTestValues.invocationID(236)
        ),
        sessionID: handshake.sessionID
      )
      Issue.record("Expected the zero replay run identity to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    } catch {
      Issue.record("Expected a gateway failure, received: \(error)")
    }
  }

  private func zeroUUID() -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }
}
