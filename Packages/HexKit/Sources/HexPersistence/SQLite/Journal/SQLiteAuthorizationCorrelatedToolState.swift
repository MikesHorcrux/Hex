enum SQLiteAuthorizationCorrelatedToolState: Codable, Equatable {
  case requested
  case allowedAwaitingStart
  case allowedStarted
  case deniedAwaitingFailure
  case finished
}
