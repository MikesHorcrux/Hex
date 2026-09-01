import Foundation

/// Optional resident control callbacks owned by the gateway composition root. A missing status
/// callback reports `.unavailable`; missing mutation callbacks fail closed with a transport error.
/// Callbacks are intentionally narrow so the XPC service cannot acquire or retain credentials.
public struct HexGatewayResidentControlHandlers: Sendable {
  public let status: (@Sendable () async throws -> GatewayResidentStatus)?
  public let pauseHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)?
  public let resumeHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)?

  public init(
    status: (@Sendable () async throws -> GatewayResidentStatus)? = nil,
    pauseHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)? = nil,
    resumeHeartbeats: (@Sendable () async throws -> GatewayResidentStatus)? = nil
  ) {
    self.status = status
    self.pauseHeartbeats = pauseHeartbeats
    self.resumeHeartbeats = resumeHeartbeats
  }

  public static let unavailable = Self()
}
