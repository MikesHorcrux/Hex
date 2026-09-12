import HexCore

enum HexGatewayPeekabooCallPolicyKind: Equatable, Sendable {
  case observation
  case read
  case mutation
  case unsupported
}
