import Foundation

/// Optional resident control callbacks owned by the gateway composition root. A missing status
/// callback reports `.unavailable`; missing mutation callbacks fail closed with a transport error.
/// Callbacks are intentionally narrow so the XPC service cannot acquire or retain credentials.
public struct HexGatewayResidentControlHandlers: Sendable {
  public let status: (@Sendable () async throws -> GatewayResidentStatus)?
  public let pauseHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)?
  public let resumeHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)?
  public let listHeartbeats: (@Sendable () async throws -> GatewayHeartbeatScheduleList)?
  public let addHeartbeat:
    (@Sendable (GatewayHeartbeatScheduleRequest) async throws -> GatewayHeartbeatScheduleList)?
  public let removeHeartbeat:
    (@Sendable (GatewayHeartbeatScheduleMutation) async throws -> GatewayHeartbeatScheduleList)?
  public let pauseHeartbeat:
    (@Sendable (GatewayHeartbeatScheduleMutation) async throws -> GatewayHeartbeatScheduleList)?
  public let resumeHeartbeat:
    (@Sendable (GatewayHeartbeatScheduleMutation) async throws -> GatewayHeartbeatScheduleList)?

  public init(
    status: (@Sendable () async throws -> GatewayResidentStatus)? = nil,
    pauseHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)? = nil,
    resumeHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)? = nil,
    listHeartbeats: (@Sendable () async throws -> GatewayHeartbeatScheduleList)? = nil,
    addHeartbeat:
      (@Sendable (GatewayHeartbeatScheduleRequest) async throws -> GatewayHeartbeatScheduleList)? =
      nil,
    removeHeartbeat:
      (@Sendable (GatewayHeartbeatScheduleMutation) async throws -> GatewayHeartbeatScheduleList)? =
      nil,
    pauseHeartbeat:
      (@Sendable (GatewayHeartbeatScheduleMutation) async throws -> GatewayHeartbeatScheduleList)? =
      nil,
    resumeHeartbeat:
      (@Sendable (GatewayHeartbeatScheduleMutation) async throws -> GatewayHeartbeatScheduleList)? =
      nil
  ) {
    self.status = status
    self.pauseHeartbeats = pauseHeartbeats
    self.resumeHeartbeats = resumeHeartbeats
    self.listHeartbeats = listHeartbeats
    self.addHeartbeat = addHeartbeat
    self.removeHeartbeat = removeHeartbeat
    self.pauseHeartbeat = pauseHeartbeat
    self.resumeHeartbeat = resumeHeartbeat
  }

  public static let unavailable = Self()
}
