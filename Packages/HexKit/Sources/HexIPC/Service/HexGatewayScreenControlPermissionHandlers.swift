/// Screen-control permission callbacks owned by the resident gateway composition root. The request
/// callback may ask macOS to display standard consent prompts, so it must only be invoked in
/// response to an explicit user action.
public struct HexGatewayScreenControlPermissionHandlers: Sendable {
  public let status: (@Sendable () async throws -> GatewayScreenControlPermissionStatus)?
  public let request: (@Sendable () async throws -> GatewayScreenControlPermissionStatus)?

  public init(
    status: (@Sendable () async throws -> GatewayScreenControlPermissionStatus)? = nil,
    request: (@Sendable () async throws -> GatewayScreenControlPermissionStatus)? = nil
  ) {
    self.status = status
    self.request = request
  }

  public static let unavailable = Self()
}
