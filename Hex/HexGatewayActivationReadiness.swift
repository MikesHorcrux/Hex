/// Readiness for exposing start-at-login registration. The current production value is
/// deliberately blocked until the resident bundle and its credential/configuration handoff are
/// ready for a signed distribution path.
nonisolated struct HexGatewayActivationReadiness: Equatable, Sendable {
  let isReady: Bool
  let message: String

  static let blocked = Self(
    isReady: false,
    message:
      "Start at login is blocked because signed resident packaging and secure credential configuration are not complete."
  )

  static let ready = Self(isReady: true, message: "")
}
