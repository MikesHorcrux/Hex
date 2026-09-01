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
