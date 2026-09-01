import Foundation

public struct SystemHexHeartbeatClock: HexHeartbeatClock, Sendable {
  public init() {}

  public var now: Date {
    Date()
  }
}
