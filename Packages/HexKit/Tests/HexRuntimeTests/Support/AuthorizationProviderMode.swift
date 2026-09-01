import HexCore

enum AuthorizationProviderMode: Sendable {
  case decisions([AuthorizationDecision])
  case throwing
  case suspend
}
