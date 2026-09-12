/// Composition-owned management only: these callbacks never execute a model-selected tool.
public struct HexGatewayToolServerControlHandlers: Sendable {
  public let list: (@Sendable () async throws -> GatewayToolServerHealth)?
  public let refresh:
    (@Sendable (GatewayToolServerRequest) async throws -> GatewayToolServerStatus)?

  public init(
    list: (@Sendable () async throws -> GatewayToolServerHealth)? = nil,
    refresh: (@Sendable (GatewayToolServerRequest) async throws -> GatewayToolServerStatus)? = nil
  ) {
    self.list = list
    self.refresh = refresh
  }

  public static let unavailable = Self()
}
