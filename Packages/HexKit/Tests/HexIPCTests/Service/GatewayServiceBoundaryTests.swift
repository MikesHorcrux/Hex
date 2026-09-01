import HexCore
import HexIPC
import Testing

@Suite("Gateway service boundary")
struct GatewayServiceBoundaryTests {
  @Test
  func rejectsOversizedHandshakeResponseBeforeSessionMutation() async throws {
    let probeCodec = GatewayWireCodec(configuration: .standard)
    let request = GatewayTestValues.handshakeRequest(80)
    let response = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(rawValue: GatewayTestValues.uuid(80)),
      gatewayInstanceID: GatewayInstanceID(rawValue: GatewayTestValues.uuid(81)),
      selectedVersion: .current,
      activeRun: nil
    )
    let requestBytes = try probeCodec.encode(request).count
    let responseBytes = try probeCodec.encode(response).count
    #expect(requestBytes < responseBytes)
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: responseBytes - 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSessions: 1
      )
    )
    let service = HexGatewayService(
      driver: ControllableGatewayRunDriver(),
      configuration: configuration
    )

    for _ in 0..<2 {
      do {
        _ = try await service.handshake(request)
        Issue.record("Expected the oversized handshake response to be rejected.")
      } catch let failure as GatewayFailure {
        #expect(failure.code == .payloadTooLarge)
      }
    }
  }

  @Test
  func rejectsDirectOversizedStartBeforeIdempotencyMutation() async throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 512,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      )
    )
    let runID = GatewayTestValues.runID(78)
    let oversizedRequest = GatewayTestValues.request(
      runID: runID,
      text: String(repeating: "oversized", count: 512)
    )
    #expect(throws: GatewayFailure.self) {
      _ = try GatewayWireCodec(configuration: configuration).encode(oversizedRequest)
    }
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: configuration)
    let session = try await service.handshake(GatewayTestValues.handshakeRequest(78))

    do {
      _ = try await service.startRun(oversizedRequest, sessionID: session.sessionID)
      Issue.record("Expected direct oversized request rejection before state mutation.")
      await driver.waitUntilStarted(runID)
      await driver.finish(runID)
      await driver.waitUntilStopped(runID)
    } catch let failure as GatewayFailure {
      #expect(failure.code == .payloadTooLarge)
    }

    let validRequest = GatewayTestValues.request(runID: runID)
    let response = try await service.startRun(validRequest, sessionID: session.sessionID)
    #expect(response.invocationID != nil)
    guard case .started = response.disposition else {
      Issue.record("Expected the valid request to start.")
      return
    }
    await complete(runID, driver: driver)
  }

  @Test
  func rejectsDirectUnencodableStartBeforeDriverInvocation() async throws {
    let runID = GatewayTestValues.runID(79)
    let unencodableRequest = GatewayStartRunRequest(
      runID: runID,
      modelID: ModelID(rawValue: "model"),
      initialMessages: [
        Message(
          role: .assistant,
          content: [
            .toolCall(
              ToolCall(
                id: ToolCallID(rawValue: "unencodable"),
                name: "echo",
                arguments: ["value": .number(42.0)]
              )
            )
          ]
        )
      ]
    )
    #expect(throws: GatewayFailure.self) {
      _ = try GatewayWireCodec(configuration: .standard).encode(unencodableRequest)
    }
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver)
    let session = try await service.handshake(GatewayTestValues.handshakeRequest(79))

    do {
      _ = try await service.startRun(unencodableRequest, sessionID: session.sessionID)
      Issue.record("Expected direct unencodable request rejection before state mutation.")
      await driver.waitUntilStarted(runID)
      await driver.finish(runID)
      await driver.waitUntilStopped(runID)
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }
    #expect(await driver.invocationCount(for: runID) == 0)
  }

  @Test
  func serviceLimitCannotBeBypassedByLargerTransportEnvelope() async throws {
    let serviceConfiguration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 512,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      )
    )
    let driver = ControllableGatewayRunDriver()
    let service = HexGatewayService(driver: driver, configuration: serviceConfiguration)
    let transport = InProcessHexGatewayTransport(
      service: service,
      configuration: .standard
    )
    _ = try await transport.handshake(GatewayTestValues.handshakeRequest(75))
    let runID = GatewayTestValues.runID(75)
    let request = GatewayTestValues.request(
      runID: runID,
      text: String(repeating: "oversized", count: 512)
    )

    do {
      _ = try await transport.startRun(request)
      Issue.record("Expected the service's smaller envelope to reject the request.")
      await driver.waitUntilStarted(runID)
      await driver.finish(runID)
      await driver.waitUntilStopped(runID)
    } catch let failure as GatewayFailure {
      #expect(failure.code == .payloadTooLarge)
    }
    #expect(await driver.invocationCount(for: runID) == 0)
  }

  private func complete(
    _ runID: AgentRunID,
    driver: ControllableGatewayRunDriver
  ) async {
    await driver.waitUntilStarted(runID)
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 1, event: .runStarted)
    )
    await driver.yieldAndWait(
      GatewayTestValues.record(runID: runID, sequence: 2, event: .runCompleted)
    )
    await driver.finish(runID)
    await driver.waitUntilStopped(runID)
  }
}
