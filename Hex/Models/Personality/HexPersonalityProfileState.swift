enum HexPersonalityProfileState: Equatable, Sendable {
  case idle
  case loading
  case empty
  case loaded
  case corrupted(String)
  case unavailable(String)
  case failed(String)

  var isUnavailable: Bool {
    if case .unavailable = self {
      return true
    }
    return false
  }

  var message: String? {
    switch self {
    case .idle, .loading, .empty, .loaded:
      nil
    case .corrupted(let message), .unavailable(let message), .failed(let message):
      message
    }
  }
}
