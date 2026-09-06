public struct GatewayProtocolVersion: Codable, Comparable, Sendable {
  /// Version 1.12 requires acknowledged XPC event admission. Reject older binaries during the
  /// Data-only handshake, before calling the incompatible event-sink selector. Approval choices,
  /// nonexecution receipts, and bounded scheduled-run history remain part of this contract.
  /// Version 1.13 also identifies non-admission during idle tool maintenance. Older peers cannot
  /// safely interpret that new outcome, so both endpoints must implement the current contract.
  public static let minimumSupported = GatewayProtocolVersion(major: 1, minor: 13)
  /// Version 1.13 adds bounded tool-server health and targeted reconnect controls.
  public static let current = GatewayProtocolVersion(major: 1, minor: 13)

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
