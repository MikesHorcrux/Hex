import Foundation

/// Optional transport capability for resident gateway status and heartbeat controls. The lease is
/// supplied by the owning `HexGatewayClient`; implementations must bind every operation to the
/// exact authenticated connection represented by that lease.
public protocol HexGatewayResidentControlTransport: Sendable {
  func status(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus

  func pauseHeartbeats(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus

  func resumeHeartbeats(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayResidentStatus
}

extension HexGatewayResidentControlTransport {
  /// Returns the current bounded schedule projection. Implementations that do not expose the
  /// optional heartbeat-management capability fail closed instead of silently returning local data.
  public func listHeartbeats(
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "The connected gateway transport does not support heartbeat schedule management."
    )
  }

  public func addHeartbeat(
    _ request: GatewayHeartbeatScheduleRequest,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "The connected gateway transport does not support heartbeat schedule management."
    )
  }

  public func removeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "The connected gateway transport does not support heartbeat schedule management."
    )
  }

  public func pauseHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "The connected gateway transport does not support heartbeat schedule management."
    )
  }

  public func resumeHeartbeat(
    _ mutation: GatewayHeartbeatScheduleMutation,
    lease: GatewayTransportConnectionLease
  ) async throws -> GatewayHeartbeatScheduleList {
    throw GatewayFailure(
      code: .transportUnavailable,
      message: "The connected gateway transport does not support heartbeat schedule management."
    )
  }
}
