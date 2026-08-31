public enum MCPClientSessionError: Error, Equatable, Sendable {
  case notConnected
  case alreadyConnected
  case unsupportedProtocolVersion
  case toolsUnavailable
  case protocolViolation
  case limitExceeded
  case requestTimedOut
  case connectionClosed
  case remoteError(code: Int64)
}
