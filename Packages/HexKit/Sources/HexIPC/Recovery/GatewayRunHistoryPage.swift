import HexCore

/// Original durable records, not live invocation envelopes. Apply and persist before advancing.
public struct GatewayRunHistoryPage: Codable, Equatable, Sendable {
  public let gatewayInstanceID: GatewayInstanceID
  public let runID: AgentRunID
  public let firstEventID: AgentEventID
  public let afterSequence: UInt64
  public let throughSequence: UInt64
  public let records: [AgentEventRecord]
  public let nextAfterSequence: UInt64?
  public init(
    gatewayInstanceID: GatewayInstanceID, runID: AgentRunID, firstEventID: AgentEventID,
    afterSequence: UInt64, throughSequence: UInt64, records: [AgentEventRecord],
    nextAfterSequence: UInt64?
  ) {
    self.gatewayInstanceID = gatewayInstanceID
    self.runID = runID
    self.firstEventID = firstEventID
    self.afterSequence = afterSequence
    self.throughSequence = throughSequence
    self.records = records
    self.nextAfterSequence = nextAfterSequence
  }

  public func validated(for request: GatewayRunHistoryRequest) throws -> Self {
    try GatewayRunRecoveryValidation.request(request)
    try GatewayRunRecoveryValidation.identity(gatewayInstanceID.rawValue)
    try GatewayRunRecoveryValidation.page(self, request: request, instanceID: gatewayInstanceID)
    let codec = GatewayWireCodec(configuration: .standard)
    _ = try codec.encode(
      GatewayXPCResponseEnvelope(operation: .readRunHistory, body: codec.encode(self)))
    return self
  }
}
