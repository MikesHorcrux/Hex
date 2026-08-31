public struct GatewayProtocolVersion: Codable, Comparable, Sendable {
  public static let minimumSupported = GatewayProtocolVersion(major: 1, minor: 0)
  public static let current = GatewayProtocolVersion(major: 1, minor: 0)

  public let major: UInt16
  public let minor: UInt16

  public init(major: UInt16, minor: UInt16) {
    self.major = major
    self.minor = minor
  }

  public static func < (
    lhs: GatewayProtocolVersion,
    rhs: GatewayProtocolVersion
  ) -> Bool {
    if lhs.major != rhs.major {
      return lhs.major < rhs.major
    }
    return lhs.minor < rhs.minor
  }
}
