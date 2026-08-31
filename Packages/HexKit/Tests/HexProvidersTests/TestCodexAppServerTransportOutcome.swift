import HexCore

enum TestCodexAppServerTransportOutcome: Sendable {
  case value(JSONValue)
  case failure
  case cancellation
}
