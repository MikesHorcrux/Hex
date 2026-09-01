import HexCore

enum ToolAuthorizationBehavior: Sendable {
  case defaultDescription
  case request(AuthorizationRequest)
  case throwing
  case suspend
}
