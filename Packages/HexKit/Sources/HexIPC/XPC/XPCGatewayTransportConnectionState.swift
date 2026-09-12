import Foundation
import HexCore

struct XPCGatewayTransportConnectionState: Sendable {
  let generation: UUID
  let lease: GatewayTransportConnectionLease
  let sessionID: GatewaySessionID
  let selectedVersion: GatewayProtocolVersion
  let connection: any HexGatewayXPCConnection
}
