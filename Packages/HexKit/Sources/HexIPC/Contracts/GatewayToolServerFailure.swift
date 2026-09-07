/// Stable user-facing categories only. Raw server errors, executable paths and endpoints stay local.
public enum GatewayToolServerFailure: String, Codable, Equatable, Sendable {
  case componentMissing
  case configurationInvalid
  case connectionTimedOut
  case serverRejected
  case authenticationRejected
  case invalidResponse
  case connectionFailed
}
