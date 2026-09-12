enum ToolAuthorizationLedgerError: Error, Equatable, Sendable {
  case authorizationRequired
  case capacityExceeded
  case conflictingRequest
}
