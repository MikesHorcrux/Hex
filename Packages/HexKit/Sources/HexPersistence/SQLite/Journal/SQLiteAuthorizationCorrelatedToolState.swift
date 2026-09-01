enum SQLiteAuthorizationCorrelatedToolState: Equatable {
  case requested
  case allowedAwaitingStart
  case allowedStarted
  case deniedAwaitingFailure
  case finished
}
