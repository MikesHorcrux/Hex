nonisolated enum AuthorizationDecisionChoice: Equatable, Sendable {
  case allowOnce
  case allowForSession
  case deny

  var buttonTitle: String {
    switch self {
    case .allowOnce:
      "Allow Once"
    case .allowForSession:
      "Allow for Session"
    case .deny:
      "Deny"
    }
  }
}
