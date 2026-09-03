import Foundation

/// Accessibility callbacks owned by the resident gateway composition root. The request callback
/// may ask macOS to display its standard consent prompt, so it must only be invoked in response to
/// an explicit user action.
public struct HexGatewayAccessibilityPermissionHandlers: Sendable {
  public let status: (@Sendable () async throws -> GatewayAccessibilityPermissionStatus)?
  public let request: (@Sendable () async throws -> GatewayAccessibilityPermissionStatus)?

  public init(
    status: (@Sendable () async throws -> GatewayAccessibilityPermissionStatus)? = nil,
    request: (@Sendable () async throws -> GatewayAccessibilityPermissionStatus)? = nil
  ) {
    self.status = status
    self.request = request
  }

  public static let unavailable = Self()
}
