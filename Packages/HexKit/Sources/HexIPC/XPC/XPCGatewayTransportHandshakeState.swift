import Foundation
import HexCore

struct XPCGatewayTransportHandshakeState: Sendable {
  let attemptID: UUID
  let lease: GatewayTransportConnectionLease
  let connection: any HexGatewayXPCConnection
}
