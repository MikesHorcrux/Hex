@preconcurrency import Foundation
import HexCore

/// Exported-object adapter for a single NSXPCConnection. It translates bounded Data envelopes into
/// the existing `HexGatewayService` API and owns the connection's lease, session, and subscriptions.
/// A listener should create one instance per accepted NSXPCConnection and call `invalidate()` from
/// that connection's invalidation handler.
public final class HexGatewayXPCService: NSObject, HexGatewayXPCServiceProtocol {
  private let state: HexGatewayXPCServiceState

  public convenience init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable,
    accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers = .unavailable,
    screenControlPermissionHandlers: HexGatewayScreenControlPermissionHandlers = .unavailable,
    modelCatalogHandler: (@Sendable () async throws -> [ModelDescriptor])? = nil,
    artifactReadHandler:
      (@Sendable (GatewayArtifactReadRequest) async throws -> GatewayArtifactReadResponse)? = nil
  ) {
    self.init(
      service: service,
      configuration: configuration,
      authorizationDecisionHandler: nil,
      residentControlHandlers: residentControlHandlers,
      accessibilityPermissionHandlers: accessibilityPermissionHandlers,
      screenControlPermissionHandlers: screenControlPermissionHandlers,
      modelCatalogHandler: modelCatalogHandler,
      artifactReadHandler: artifactReadHandler,
      toolServerControlHandlers: .unavailable
    )
  }

  /// Creates an exported service with a handler owned by the resident composition root. The
  /// handler receives the complete request echoed by the app and the active connection's commit
  /// gate; it must pass that gate to the broker so invalidation cannot race the final commit.
  public convenience init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    authorizationDecisionHandler:
      @escaping @Sendable (
        AuthorizationRequest,
        GatewayAuthorizationDecisionChoice,
        HexGatewayAuthorizationCommitGate
      ) async throws -> Void,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable,
    accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers = .unavailable,
    screenControlPermissionHandlers: HexGatewayScreenControlPermissionHandlers = .unavailable,
    modelCatalogHandler: (@Sendable () async throws -> [ModelDescriptor])? = nil,
    artifactReadHandler:
      (@Sendable (GatewayArtifactReadRequest) async throws -> GatewayArtifactReadResponse)? = nil
  ) {
    self.init(
      service: service,
      configuration: configuration,
      authorizationDecisionHandler: authorizationDecisionHandler,
      residentControlHandlers: residentControlHandlers,
      accessibilityPermissionHandlers: accessibilityPermissionHandlers,
      screenControlPermissionHandlers: screenControlPermissionHandlers,
      modelCatalogHandler: modelCatalogHandler,
      artifactReadHandler: artifactReadHandler,
      toolServerControlHandlers: .unavailable
    )
  }

  public init(
    service: HexGatewayService,
    configuration: GatewayConfiguration = .standard,
    authorizationDecisionHandler:
      (
        @Sendable (
          AuthorizationRequest, GatewayAuthorizationDecisionChoice,
          HexGatewayAuthorizationCommitGate
        )
          async throws -> Void
      )? = nil,
    residentControlHandlers: HexGatewayResidentControlHandlers = .unavailable,
    accessibilityPermissionHandlers: HexGatewayAccessibilityPermissionHandlers = .unavailable,
    screenControlPermissionHandlers: HexGatewayScreenControlPermissionHandlers = .unavailable,
    modelCatalogHandler: (@Sendable () async throws -> [ModelDescriptor])? = nil,
    artifactReadHandler:
      (@Sendable (GatewayArtifactReadRequest) async throws -> GatewayArtifactReadResponse)? = nil,
    permissionManagementHandlers: HexGatewayPermissionManagementHandlers = .unavailable,
    toolServerControlHandlers: HexGatewayToolServerControlHandlers
  ) {
    state = HexGatewayXPCServiceState(
      service: service, configuration: configuration,
      authorizationDecisionHandler: authorizationDecisionHandler,
      residentControlHandlers: residentControlHandlers,
      toolServerControlHandlers: toolServerControlHandlers,
      accessibilityPermissionHandlers: accessibilityPermissionHandlers,
      screenControlPermissionHandlers: screenControlPermissionHandlers,
      permissionManagementHandlers: permissionManagementHandlers,
      modelCatalogHandler: modelCatalogHandler, artifactReadHandler: artifactReadHandler)
    super.init()
  }

  /// Configures both the exported and imported XPC interfaces for this Data-only protocol.
  public static func interface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: HexGatewayXPCServiceProtocol.self)
    let eventSinkInterface = NSXPCInterface(with: HexGatewayXPCEventSinkProtocol.self)
    interface.setInterface(
      eventSinkInterface,
      for: NSSelectorFromString("subscribe:sink:withReply:"),
      argumentIndex: 1,
      ofReply: false
    )
    return interface
  }

  /// Call this from the NSXPCConnection invalidation handler. It is safe to call more than once.
  public func invalidate() {
    let state = self.state
    Task {
      await state.invalidate()
    }
  }

  public func request(_ envelope: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
    let state = self.state
    Task {
      reply(await state.request(envelope))
    }
  }

  public func subscribe(
    _ envelope: Data,
    sink: HexGatewayXPCEventSinkProtocol,
    withReply reply: @escaping @Sendable (Data) -> Void
  ) {
    let bridge = GatewayXPCEventSinkBridge(sink: sink)
    let state = self.state
    Task {
      reply(await state.subscribe(envelope, sink: bridge))
    }
  }
}
