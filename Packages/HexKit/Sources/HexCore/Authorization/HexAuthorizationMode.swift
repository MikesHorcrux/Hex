/// The user-owned approval policy applied by the resident Hex runtime.
///
/// Full access affects Hex's interactive approval step only. Capability-specific validation,
/// workspace boundaries, network policy, and macOS privacy controls remain authoritative.
public enum HexAuthorizationMode: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
  case askEveryTime = "ask-every-time"
  case fullAccess = "full-access"

  public var id: String { rawValue }
}
