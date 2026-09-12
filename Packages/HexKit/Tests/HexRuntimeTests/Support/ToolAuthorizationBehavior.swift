import HexCore

enum ToolAuthorizationBehavior: Sendable {
  case defaultDescription
  case request(AuthorizationRequest)
  case invalidArguments
  case throwing
  case suspend
}
