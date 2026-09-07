import HexCore

/// A transient edit; the value is never encoded into resident settings or diagnostics.
struct HexMCPSecretChange: Sendable {
  let key: HexSecretKey
  let value: String?
}
