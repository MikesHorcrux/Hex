/// Readiness for exposing start-at-login registration. Debug computes this from the signed bundle,
/// persisted settings, and credential presence; unsupported compositions use the blocked value.
nonisolated struct HexGatewayActivationReadiness: Equatable, Sendable {
  let isReady: Bool
  let message: String

  static let blocked = Self(
    isReady: false,
    message: "Resident activation is unavailable in this build."
  )

  static let ready = Self(isReady: true, message: "")
}
