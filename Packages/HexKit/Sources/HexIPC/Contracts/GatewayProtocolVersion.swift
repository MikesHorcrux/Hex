public struct GatewayProtocolVersion: Codable, Comparable, Sendable {
  /// Version 1.3 adds authenticated, resident-process Accessibility permission operations. The app
  /// cannot safely infer those results from a 1.2 gateway, so older peers fail during negotiation.
  public static let minimumSupported = GatewayProtocolVersion(major: 1, minor: 3)
  public static let current = GatewayProtocolVersion(major: 1, minor: 3)

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
