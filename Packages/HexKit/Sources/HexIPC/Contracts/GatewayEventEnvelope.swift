import HexCore

/// A gateway event bound to the exact server-issued invocation that produced it.
///
/// `AgentEventRecord` identifies a logical run but intentionally has no gateway-generation field.
/// The envelope prevents a delayed or hostile transport from relabelling a record from an evicted
/// invocation as output from a newer invocation that reused the same run identifier.
public struct GatewayEventEnvelope: Codable, Equatable, Sendable {
  public let invocationID: GatewayRunInvocationID
  public let record: AgentEventRecord

  public init(
    invocationID: GatewayRunInvocationID,
    record: AgentEventRecord
  ) {
    self.invocationID = invocationID
    self.record = record
  }
}
