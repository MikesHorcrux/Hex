import HexCore
import HexIPC
import Testing

@Suite("Gateway handshake concurrency")
struct GatewayHandshakeConcurrencyTests {
  @Test
  func concurrentReconnectsLeaveNoSupersededServiceSessions() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 8_388_608,
        maximumRetainedRecordsPerRun: 8,
        subscriberBufferCapacity: 8,
        maximumSessions: 64
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let setupTransport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration
    )
    _ = try await setupTransport.handshake(GatewayTestValues.handshakeRequest(77))
    let runID = GatewayTestValues.runID(77)
    _ = try await setupTransport.startRun(GatewayTestValues.request(runID: runID))
    await driver.waitUntilStarted(runID)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yield(
      GatewayTestValues.record(
        runID: runID,
        sequence: 2,
        event: .messageAppended(
          Message(
            role: .assistant,
            content: [.text(String(repeating: "x", count: 7_300_000))]
          )
        )
      )
    )
    await Task.yield()

    let reconnectingTransport = InProcessHexGatewayTransport(
      service: service,
      configuration: configuration
    )
    let outcomes = await withTaskGroup(of: GatewayFailureCode?.self) { group in
      for _ in 0..<32 {
        group.addTask {
          do {
            _ = try await reconnectingTransport.handshake(
              GatewayHandshakeRequest(clientID: GatewayClientID())
            )
            return nil
          } catch let failure as GatewayFailure {
            return failure.code
          } catch {
            return .transportUnavailable
          }
        }
      }
      var values: [GatewayFailureCode?] = []
      for await outcome in group {
        values.append(outcome)
      }
      return values
    }
    #expect(outcomes.contains { $0 == nil })
    #expect(outcomes.allSatisfy { $0 == nil || $0 == .disconnected })

    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 3, event: .runCompleted)
    )
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)
    await reconnectingTransport.disconnect()
    await setupTransport.disconnect()

    var newlyAvailableSessions = 0
    for _ in 0..<64 {
      do {
        _ = try await service.handshake(
          GatewayHandshakeRequest(clientID: GatewayClientID())
        )
        newlyAvailableSessions += 1
      } catch let failure as GatewayFailure {
        #expect(failure.code == .capacityExceeded)
        break
      }
    }
    #expect(newlyAvailableSessions == 64)
  }
}
