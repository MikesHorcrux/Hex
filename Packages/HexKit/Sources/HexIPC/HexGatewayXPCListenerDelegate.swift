@preconcurrency import Foundation

/// Minimal listener delegate for a gateway process that already owns an NSXPCListener. It only
/// configures accepted connections; creating the listener, advertising its Mach service, and
/// keeping the gateway process alive remain composition-root responsibilities.
public final class HexGatewayXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
  private let serviceFactory: () -> HexGatewayXPCService

  public init(serviceFactory: @escaping () -> HexGatewayXPCService) {
    self.serviceFactory = serviceFactory
    super.init()
  }

  public func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection newConnection: NSXPCConnection
  ) -> Bool {
    let service = serviceFactory()
    newConnection.exportedInterface = HexGatewayXPCService.interface()
    newConnection.exportedObject = service
    newConnection.invalidationHandler = {
      service.invalidate()
    }
    newConnection.interruptionHandler = {
      service.invalidate()
    }
    newConnection.activate()
    return true
  }
}
