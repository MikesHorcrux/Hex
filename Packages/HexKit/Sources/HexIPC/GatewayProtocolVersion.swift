public struct GatewayProtocolVersion: Codable, Comparable, Sendable {
  /// Version 1.1 adds mandatory run-invocation identity to replay and cancellation contracts. The
  /// gateway cannot safely serve 1.0 clients because a reused run identifier is ambiguous there.
  public static let minimumSupported = GatewayProtocolVersion(major: 1, minor: 1)
  public static let current = GatewayProtocolVersion(major: 1, minor: 1)

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
