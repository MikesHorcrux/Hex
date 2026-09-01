import Foundation

/// Dependency-injected physical XPC connection seam. Production uses
/// `NativeHexGatewayXPCConnection`; tests provide an actor fake without installing an XPC service.
public protocol HexGatewayXPCConnection: Sendable {
  func request(_ envelope: Data) async throws -> Data

  func subscribe(
    _ envelope: Data,
    bufferCapacity: Int
  ) async throws -> GatewayXPCEventSubscription

  func cancelSubscription(_ envelope: Data) async

  func invalidate() async
}
