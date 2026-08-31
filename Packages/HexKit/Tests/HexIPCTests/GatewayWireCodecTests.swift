import Foundation
import HexCore
import HexIPC
import Testing

@Suite("Gateway wire codec")
struct GatewayWireCodecTests {
  @Test
  func standardEnvelopeFitsRuntimeEventsWithBoundedReplayAndForwarding() throws {
    let configuration = GatewayConfiguration.standard
    let runtimeStandardJournalEventBytes = 7_340_032
    let recordEnvelopeReserveBytes = 1_048_576

    #expect(configuration.maximumWireBytes == 8_388_608)
    #expect(
      configuration.maximumWireBytes
        >= runtimeStandardJournalEventBytes + recordEnvelopeReserveBytes
    )
    #expect(configuration.maximumRetainedRecordsPerRun == 8)
    #expect(configuration.maximumRetainedWireBytesPerRun == 33_554_432)
    #expect(configuration.subscriberBufferCapacity == 8)
    #expect(configuration.maximumSubscribersPerRun == 2)
    #expect(configuration.maximumRememberedRuns == 4)

    let bufferedWireBytesPerSubscriber =
      configuration.maximumWireBytes * configuration.subscriberBufferCapacity
    let serviceSubscriberWireBytes =
      bufferedWireBytesPerSubscriber * configuration.maximumSubscribersPerRun
    let transportSubscriberWireBytes = serviceSubscriberWireBytes
    let retainedWireBytes =
      configuration.maximumRetainedWireBytesPerRun * configuration.maximumRememberedRuns
    #expect(
      serviceSubscriberWireBytes + transportSubscriberWireBytes + retainedWireBytes
        == 402_653_184
    )

    let multiMiBRuntimeRecord = GatewayTestValues.record(
      runID: GatewayTestValues.runID(),
      sequence: 2,
      event: .messageAppended(
        Message(
          role: .assistant,
          content: [.text(String(repeating: "x", count: 2_097_152))]
        )
      )
    )
    let codec = GatewayWireCodec(configuration: configuration)
    let encodedRecord = try codec.encode(multiMiBRuntimeRecord)
    #expect(encodedRecord.count > 1_048_576)
    #expect(try codec.decode(AgentEventRecord.self, from: encodedRecord) == multiMiBRuntimeRecord)
  }

  @Test
  func roundTripsVersionedDTOsAndEventSchema() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    let handshake = GatewayTestValues.handshakeRequest()
    let runID = GatewayTestValues.runID()
    let invocationID = GatewayTestValues.invocationID()
    let record = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )
    let cursor = GatewayEventCursor(
      runID: runID,
      invocationID: invocationID,
      sequence: 1
    )
    let cancellation = GatewayCancelRunRequest(
      runID: runID,
      invocationID: invocationID
    )
    let cancellationResponse = GatewayCancelRunResponse(
      runID: runID,
      invocationID: invocationID,
      disposition: .requested
    )
    let snapshot = GatewayRunSnapshot(
      runID: runID,
      invocationID: invocationID,
      phase: .running,
      latestSequence: 1
    )
    let startResponses = [
      GatewayStartRunResponse(
        runID: runID,
        disposition: .started(invocationID: invocationID)
      ),
      GatewayStartRunResponse(
        runID: runID,
        disposition: .alreadyRunning(invocationID: invocationID)
      ),
      GatewayStartRunResponse(
        runID: runID,
        disposition: .alreadyTerminal(invocationID: invocationID)
      ),
      GatewayStartRunResponse(
        runID: runID,
        disposition: .busy(activeRunID: GatewayTestValues.runID(3))
      ),
    ]

    #expect(try codec.roundTrip(handshake) == handshake)
    #expect(try codec.roundTrip(record) == record)
    #expect(try codec.roundTrip(record).schemaVersion == 1)
    #expect(try codec.roundTrip(cursor) == cursor)
    #expect(try codec.roundTrip(cancellation) == cancellation)
    #expect(try codec.roundTrip(cancellationResponse) == cancellationResponse)
    #expect(try codec.roundTrip(snapshot) == snapshot)
    #expect(try startResponses.map(codec.roundTrip) == startResponses)
    #expect(
      String(decoding: try codec.encode(invocationID), as: UTF8.self)
        == "\"\(invocationID.rawValue.uuidString)\""
    )
  }

  @Test
  func rejectsMissingAndMalformedRunInvocationIdentity() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    let runID = GatewayTestValues.runID().rawValue.uuidString
    let missingCursorIdentity = Data(
      "{\"runID\":\"\(runID)\",\"sequence\":0}".utf8
    )
    let malformedCancellationIdentity = Data(
      "{\"invocationID\":\"not-a-uuid\",\"runID\":\"\(runID)\"}".utf8
    )
    let validStartResponse = GatewayStartRunResponse(
      runID: GatewayTestValues.runID(),
      disposition: .started(invocationID: GatewayTestValues.invocationID())
    )
    var startObject = try #require(
      JSONSerialization.jsonObject(with: codec.encode(validStartResponse))
        as? [String: Any]
    )
    var dispositionObject = try #require(startObject["disposition"] as? [String: Any])
    var startedObject = try #require(dispositionObject["started"] as? [String: Any])
    startedObject.removeValue(forKey: "invocationID")
    dispositionObject["started"] = startedObject
    startObject["disposition"] = dispositionObject
    let missingStartIdentity = try JSONSerialization.data(withJSONObject: startObject)

    try expectMalformedPayload(GatewayEventCursor.self, data: missingCursorIdentity, codec: codec)
    try expectMalformedPayload(
      GatewayCancelRunRequest.self,
      data: malformedCancellationIdentity,
      codec: codec
    )
    try expectMalformedPayload(
      GatewayStartRunResponse.self,
      data: missingStartIdentity,
      codec: codec
    )
  }

  @Test
  func rejectsMalformedAndOversizedPayloads() throws {
    let configuration = try #require(
      GatewayConfiguration(
        maximumWireBytes: 16,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      )
    )
    let codec = GatewayWireCodec(configuration: configuration)

    do {
      _ = try codec.decode(GatewayHandshakeRequest.self, from: Data([0xFF]))
      Issue.record("Expected malformed JSON to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }

    do {
      _ = try codec.decode(
        GatewayHandshakeRequest.self,
        from: Data(repeating: 0, count: 17)
      )
      Issue.record("Expected oversized input to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .payloadTooLarge)
    }

    do {
      _ = try codec.encode(GatewayTestValues.handshakeRequest())
      Issue.record("Expected oversized encoded output to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .payloadTooLarge)
    }
  }

  private func expectMalformedPayload<Value: Decodable & Sendable>(
    _ type: Value.Type,
    data: Data,
    codec: GatewayWireCodec
  ) throws {
    do {
      _ = try codec.decode(type, from: data)
      Issue.record("Expected the malformed invocation identity to be rejected.")
    } catch let failure as GatewayFailure {
      #expect(failure.code == .malformedPayload)
    }
  }

  @Test
  func rejectsInvalidBounds() {
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 0,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      ) == nil
    )
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 2,
        subscriberBufferCapacity: 1
      ) == nil
    )
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 2,
        maximumRetainedRecordsPerRun: 1,
        maximumRetainedWireBytesPerRun: 1,
        subscriberBufferCapacity: 1
      ) == nil
    )
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 0
      ) == nil
    )
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSessions: 0
      ) == nil
    )
  }

  @Test
  func rejectsAttackerSizedAndAboveHardCapBounds() {
    let attackerSizedConfigurations = [
      GatewayConfiguration(
        maximumWireBytes: Int.max,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: Int.max,
        subscriberBufferCapacity: Int.max
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        maximumRetainedWireBytesPerRun: Int.max,
        subscriberBufferCapacity: 1
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: Int.max
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: Int.max
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSessions: Int.max
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumRememberedRuns: Int.max
      ),
    ]
    #expect(attackerSizedConfigurations.allSatisfy { $0 == nil })

    let aboveHardCapConfigurations = [
      GatewayConfiguration(
        maximumWireBytes: 16_777_217,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 257,
        subscriberBufferCapacity: 257
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        maximumRetainedWireBytesPerRun: 134_217_729,
        subscriberBufferCapacity: 1,
        maximumRememberedRuns: 1
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 257
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSubscribersPerRun: 5
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumSessions: 65
      ),
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 1,
        maximumRememberedRuns: 129
      ),
    ]
    #expect(aboveHardCapConfigurations.allSatisfy { $0 == nil })
  }

  @Test
  func rejectsUnsafeComposedBufferAndReplayBudgets() {
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 8_388_608,
        maximumRetainedRecordsPerRun: 1,
        subscriberBufferCapacity: 9
      ) == nil
    )
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 8_388_608,
        maximumRetainedRecordsPerRun: 8,
        subscriberBufferCapacity: 8,
        maximumSubscribersPerRun: 3
      ) == nil
    )
    #expect(
      GatewayConfiguration(
        maximumWireBytes: 1,
        maximumRetainedRecordsPerRun: 1,
        maximumRetainedWireBytesPerRun: 33_554_432,
        subscriberBufferCapacity: 1,
        maximumRememberedRuns: 5
      ) == nil
    )
  }
}
