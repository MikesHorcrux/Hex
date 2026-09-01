public enum GatewayCancelRunDisposition: String, Codable, Equatable, Sendable {
  case requested
  case alreadyTerminal
  case notFound
}
