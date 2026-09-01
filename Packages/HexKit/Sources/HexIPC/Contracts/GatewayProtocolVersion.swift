public struct GatewayProtocolVersion: Codable, Comparable, Sendable {
  /// Version 1.2 binds every streamed event to its server-issued run invocation. The gateway cannot
  /// safely serve earlier clients because a bare record can be reclassified after run-ID reuse.
  public static let minimumSupported = GatewayProtocolVersion(major: 1, minor: 2)
  public static let current = GatewayProtocolVersion(major: 1, minor: 2)

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
