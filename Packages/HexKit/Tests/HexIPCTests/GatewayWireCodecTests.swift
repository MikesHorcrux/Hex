import Foundation
import HexIPC
import Testing

@Suite("Gateway wire codec")
struct GatewayWireCodecTests {
  @Test
  func roundTripsVersionedDTOsAndEventSchema() throws {
    let codec = GatewayWireCodec(configuration: .standard)
    let handshake = GatewayTestValues.handshakeRequest()
    let runID = GatewayTestValues.runID()
    let record = GatewayTestValues.record(
      runID: runID,
      sequence: 1,
      event: .runStarted
    )

    #expect(try codec.roundTrip(handshake) == handshake)
    #expect(try codec.roundTrip(record) == record)
    #expect(try codec.roundTrip(record).schemaVersion == 1)
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
}
