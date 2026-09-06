/// A bounded, host-owned health category. Never carries server output or configuration values.
public enum MCPManagedToolFailure: String, Equatable, Sendable {
  case componentMissing
  case configurationInvalid
  case connectionTimedOut
  case serverRejected
  case invalidResponse
  case connectionFailed

  static func classify(_ error: any Error) -> Self {
    switch error {
    case let error as MCPManagedToolLayoutError:
      switch error {
      case .invalidInstallation: return .componentMissing
      case .invalidRoot: return .configurationInvalid
      }
    case is MCPServerConfigurationError, is MCPExecutableSnapshotPolicyError:
      return .configurationInvalid
    case let error as MCPClientSessionError:
      switch error {
      case .requestTimedOut: return .connectionTimedOut
      case .unsupportedProtocolVersion, .toolsUnavailable, .remoteError: return .serverRejected
      case .protocolViolation, .limitExceeded: return .invalidResponse
      case .notConnected, .alreadyConnected, .connectionClosed: return .connectionFailed
      }
    case let error as MCPToolExecutorError:
      switch error {
      case .invalidSession: return .configurationInvalid
      case .invalidToolDefinition, .duplicateTool, .invalidToolResult: return .invalidResponse
      case .notStarted, .unknownTool, .transitionInProgress: return .connectionFailed
      }
    case is DecodingError:
      return .invalidResponse
    default:
      return .connectionFailed
    }
  }
}
