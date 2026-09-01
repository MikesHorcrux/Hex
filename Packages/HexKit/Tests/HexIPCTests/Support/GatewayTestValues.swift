import Foundation
import HexCore
import HexIPC

enum GatewayTestValues {
  static func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }

  static func runID(_ value: UInt8 = 1) -> AgentRunID {
    AgentRunID(rawValue: uuid(value))
  }

  static func invocationID(_ value: UInt8 = 2) -> GatewayRunInvocationID {
    GatewayRunInvocationID(rawValue: uuid(value))
  }

  static func request(
    runID: AgentRunID,
    text: String = "hello"
  ) -> GatewayStartRunRequest {
    GatewayStartRunRequest(
      runID: runID,
      modelID: ModelID(rawValue: "test-model"),
      initialMessages: [
        Message(
          id: MessageID(rawValue: uuid(200)),
          role: .user,
          content: [.text(text)]
        )
      ]
    )
  }

  static func record(
    runID: AgentRunID,
    sequence: UInt64,
    schemaVersion: UInt16 = 1,
    event: AgentEvent
  ) -> AgentEventRecord {
    AgentEventRecord(
      id: AgentEventID(rawValue: uuid(UInt8(truncatingIfNeeded: sequence))),
      runID: runID,
      sequence: sequence,
      timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
      schemaVersion: schemaVersion,
      event: event
    )
  }

  static func handshakeRequest(_ value: UInt8 = 10) -> GatewayHandshakeRequest {
    GatewayHandshakeRequest(clientID: GatewayClientID(rawValue: uuid(value)))
  }

  static func collect(
    _ stream: AsyncThrowingStream<AgentEventRecord, any Error>
  ) async throws -> [AgentEventRecord] {
    var records: [AgentEventRecord] = []
    for try await record in stream {
      records.append(record)
    }
    return records
  }

  static func collect(
    _ stream: AsyncThrowingStream<GatewayEventEnvelope, any Error>
  ) async throws -> [AgentEventRecord] {
    var records: [AgentEventRecord] = []
    for try await envelope in stream {
      records.append(envelope.record)
    }
    return records
  }
}
