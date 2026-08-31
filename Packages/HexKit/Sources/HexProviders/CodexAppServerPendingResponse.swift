import HexCore

enum CodexAppServerPendingResponse: Equatable, Sendable {
  case result(JSONValue)
  case remoteError(Int64)
}
