import Foundation

public protocol HexHeartbeatClock: Sendable {
  var now: Date { get }
}
