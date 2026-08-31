enum CodexAppServerConnectionState: Equatable, Sendable {
  case disconnected
  case opening
  case handshaking
  case ready
  case closing
  case retired
}
