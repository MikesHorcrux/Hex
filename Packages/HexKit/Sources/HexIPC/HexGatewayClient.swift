import Foundation
import HexCore

/// App-facing gateway client with in-memory, explicitly acknowledged replay cursors keyed by exact
/// run invocation. Cursor state is not durable across app termination; callers must apply each record
/// before acknowledging it with the invocation identity that produced it.
public actor HexGatewayClient {
  let transport: any HexGatewayTransport
  let handshakeRequest: GatewayHandshakeRequest
  var gatewayInstanceID: GatewayInstanceID?
  var acknowledgedSequences: [GatewayRunAcknowledgementKey: UInt64] = [:]
  var startAttemptIDs: [AgentRunID: GatewayClientStartAttemptID] = [:]
  var connectionAttemptID: GatewayClientConnectionAttemptID?
  var connectionGenerationID = GatewayClientConnectionGenerationID()
  var connectedGenerationID: GatewayClientConnectionGenerationID?
  var eventStreams: [UUID: GatewayClientEventStreamState] = [:]

  public init(
    transport: any HexGatewayTransport,
    clientID: GatewayClientID = GatewayClientID(),
    minimumVersion: GatewayProtocolVersion = .minimumSupported,
    maximumVersion: GatewayProtocolVersion = .current
  ) {
    self.transport = transport
    handshakeRequest = GatewayHandshakeRequest(
      clientID: clientID,
      minimumVersion: minimumVersion,
      maximumVersion: maximumVersion
    )
  }

  public func acknowledgedCursor(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) -> GatewayEventCursor {
    let key = GatewayRunAcknowledgementKey(runID: runID, invocationID: invocationID)
    return GatewayEventCursor(
      runID: runID,
      invocationID: invocationID,
      sequence: acknowledgedSequences[key] ?? 0
    )
  }

  /// Returns false for an already-applied record and fails closed if applying the record would skip a
  /// sequence. A true result does not advance the cursor; call `acknowledge` only after reduction.
  public func shouldApply(
    _ record: AgentEventRecord,
    invocationID: GatewayRunInvocationID
  ) throws -> Bool {
    let key = GatewayRunAcknowledgementKey(
      runID: record.runID,
      invocationID: invocationID
    )
    let acknowledgedSequence = acknowledgedSequences[key] ?? 0
    if record.sequence <= acknowledgedSequence {
      return false
    }

    let expectedSequence = acknowledgedSequence.addingReportingOverflow(1)
    guard !expectedSequence.overflow, record.sequence == expectedSequence.partialValue else {
      throw GatewayFailure(
        code: .invalidEventSequence,
        message: "The client cannot apply an event record with a sequence gap."
      )
    }
    return true
  }

  public func acknowledge(
    _ record: AgentEventRecord,
    invocationID: GatewayRunInvocationID
  ) throws {
    let key = GatewayRunAcknowledgementKey(
      runID: record.runID,
      invocationID: invocationID
    )
    let acknowledgedSequence = acknowledgedSequences[key] ?? 0
    if record.sequence <= acknowledgedSequence {
      return
    }

    let expectedSequence = acknowledgedSequence.addingReportingOverflow(1)
    guard !expectedSequence.overflow, record.sequence == expectedSequence.partialValue else {
      throw GatewayFailure(
        code: .invalidEventSequence,
        message: "The client cannot acknowledge an event record with a sequence gap."
      )
    }
    acknowledgedSequences[key] = record.sequence
  }

  public func forgetAcknowledgement(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) {
    acknowledgedSequences.removeValue(
      forKey: GatewayRunAcknowledgementKey(
        runID: runID,
        invocationID: invocationID
      )
    )
  }

  func removeAcknowledgements(
    for runID: AgentRunID,
    except retainedInvocationID: GatewayRunInvocationID? = nil
  ) {
    acknowledgedSequences = acknowledgedSequences.filter { entry in
      entry.key.runID != runID || entry.key.invocationID == retainedInvocationID
    }
  }

  func supersededOperationFailure() -> GatewayFailure {
    GatewayFailure(
      code: .supersededOperation,
      message: "The gateway client operation was superseded."
    )
  }
}
