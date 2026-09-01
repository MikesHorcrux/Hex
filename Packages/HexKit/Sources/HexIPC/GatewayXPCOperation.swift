import Foundation

/// Operations carried by the Hex XPC boundary. The payload for every operation is a bounded
/// `GatewayWireCodec` Data value; XPC never receives an unbounded Codable object graph.
public enum GatewayXPCOperation: String, Codable, Hashable, Sendable {
  case handshake
  case startRun
  case cancelRun
  case subscribeEvents
  case cancelSubscription
  case disconnect
}
