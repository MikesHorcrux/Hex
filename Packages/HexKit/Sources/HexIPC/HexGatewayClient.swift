import Foundation
import HexCore

/// App-facing gateway client with in-memory, explicitly acknowledged replay cursors keyed by exact
/// run invocation. Cursor state is not durable across app termination; callers must apply each
/// invocation-bound envelope before acknowledging that same envelope.
public actor HexGatewayClient {
  let transport: any HexGatewayTransport
  let configuration: GatewayConfiguration
  let configuredMinimumVersion: GatewayProtocolVersion
  let configuredMaximumVersion: GatewayProtocolVersion
  let handshakeRequest: GatewayHandshakeRequest
  var gatewayInstanceID: GatewayInstanceID?
  var acknowledgedSequences: [GatewayRunAcknowledgementKey: UInt64] = [:]
  var terminalAcknowledgements: Set<GatewayRunAcknowledgementKey> = []
  var acknowledgementOrder: [GatewayRunAcknowledgementKey] = []
  var startAttemptIDs: [AgentRunID: GatewayClientStartAttemptID] = [:]
  var connectionAttemptID: GatewayClientConnectionAttemptID?
  var connectionGenerationID = GatewayClientConnectionGenerationID()
  var connectionLease: GatewayTransportConnectionLease?
  var connectedGenerationID: GatewayClientConnectionGenerationID?
  var connectedLease: GatewayTransportConnectionLease?
  var eventStreams: [UUID: GatewayClientEventStreamState] = [:]
  var eventStreamReservations: [UUID: GatewayClientEventStreamReservation] = [:]
  // Physical IDs intentionally survive reconnect cleanup until their transport calls return.
  var physicalEventStreamAcquisitionIDs: Set<UUID> = []
  var eventStreamAcquisitionWaiters: [GatewayClientEventStreamAcquisitionWaiter] = []

  public init(
    transport: any HexGatewayTransport,
    clientID: GatewayClientID = GatewayClientID(),
    minimumVersion: GatewayProtocolVersion = .minimumSupported,
    maximumVersion: GatewayProtocolVersion = .current,
    configuration: GatewayConfiguration = .standard
  ) {
    self.transport = transport
    self.configuration = configuration
    configuredMinimumVersion = minimumVersion
    configuredMaximumVersion = maximumVersion
    let intersectedMinimum =
      minimumVersion > GatewayProtocolVersion.minimumSupported
      ? minimumVersion
      : GatewayProtocolVersion.minimumSupported
    let intersectedMaximum =
      maximumVersion < GatewayProtocolVersion.current
      ? maximumVersion
      : GatewayProtocolVersion.current
    handshakeRequest = GatewayHandshakeRequest(
      clientID: clientID,
      minimumVersion: intersectedMinimum,
      maximumVersion: intersectedMaximum
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
  public func shouldApply(_ envelope: GatewayEventEnvelope) throws -> Bool {
    try validateEventRoute(
      runID: envelope.record.runID,
      invocationID: envelope.invocationID
    )
    let record = try validateEventEnvelope(
      envelope,
      runID: envelope.record.runID,
      invocationID: envelope.invocationID,
      requiredSequence: envelope.record.sequence
    )
    let key = GatewayRunAcknowledgementKey(
      runID: record.runID,
      invocationID: envelope.invocationID
    )
    let acknowledgedSequence = acknowledgedSequences[key] ?? 0
    if record.sequence <= acknowledgedSequence {
      return false
    }
    guard !terminalAcknowledgements.contains(key) else {
      throw eventAfterTerminalFailure()
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

  public func acknowledge(_ envelope: GatewayEventEnvelope) throws {
    try validateEventRoute(
      runID: envelope.record.runID,
      invocationID: envelope.invocationID
    )
    let record = try validateEventEnvelope(
      envelope,
      runID: envelope.record.runID,
      invocationID: envelope.invocationID,
      requiredSequence: envelope.record.sequence
    )
    let key = GatewayRunAcknowledgementKey(
      runID: record.runID,
      invocationID: envelope.invocationID
    )
    let acknowledgedSequence = acknowledgedSequences[key] ?? 0
    if record.sequence <= acknowledgedSequence {
      return
    }
    guard !terminalAcknowledgements.contains(key) else {
      throw eventAfterTerminalFailure()
    }

    let expectedSequence = acknowledgedSequence.addingReportingOverflow(1)
    guard !expectedSequence.overflow, record.sequence == expectedSequence.partialValue else {
      throw GatewayFailure(
        code: .invalidEventSequence,
        message: "The client cannot acknowledge an event record with a sequence gap."
      )
    }
    storeAcknowledgement(record.sequence, for: key)
    if isTerminal(record.event) {
      terminalAcknowledgements.insert(key)
    }
  }

  public func forgetAcknowledgement(
    for runID: AgentRunID,
    invocationID: GatewayRunInvocationID
  ) {
    removeAcknowledgement(
      for: GatewayRunAcknowledgementKey(runID: runID, invocationID: invocationID)
    )
  }

  func removeAcknowledgements(
    for runID: AgentRunID,
    except retainedInvocationID: GatewayRunInvocationID? = nil
  ) {
    let removedKeys = acknowledgedSequences.keys.filter { key in
      key.runID == runID && key.invocationID != retainedInvocationID
    }
    for key in removedKeys {
      removeAcknowledgement(for: key)
    }
  }

  func storeAcknowledgement(
    _ sequence: UInt64,
    for key: GatewayRunAcknowledgementKey
  ) {
    acknowledgedSequences[key] = sequence
    acknowledgementOrder.removeAll { $0 == key }
    acknowledgementOrder.append(key)

    while acknowledgementOrder.count > configuration.maximumRememberedRuns {
      let evictedKey = acknowledgementOrder.removeFirst()
      acknowledgedSequences.removeValue(forKey: evictedKey)
      terminalAcknowledgements.remove(evictedKey)
    }
  }

  func removeAcknowledgement(for key: GatewayRunAcknowledgementKey) {
    acknowledgedSequences.removeValue(forKey: key)
    terminalAcknowledgements.remove(key)
    acknowledgementOrder.removeAll { $0 == key }
  }

  func removeAllAcknowledgements() {
    acknowledgedSequences.removeAll(keepingCapacity: true)
    terminalAcknowledgements.removeAll(keepingCapacity: true)
    acknowledgementOrder.removeAll(keepingCapacity: true)
  }

  func supersededOperationFailure() -> GatewayFailure {
    GatewayFailure(
      code: .supersededOperation,
      message: "The gateway client operation was superseded."
    )
  }
}
