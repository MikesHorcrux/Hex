import HexIPC
import HexMCP

/// Converts resident screen-control failures into bounded, actionable messages that can safely
/// cross the XPC boundary without exposing subprocess details or local paths.
enum HexGatewayScreenControlPermissionFailureMapper {
  static func map(_ error: any Error) -> GatewayFailure {
    if let failure = error as? GatewayFailure {
      return failure
    }

    let message: String
    switch error {
    case MCPManagedToolLayoutError.invalidInstallation(.peekaboo):
      message =
        "Screen control is missing or failed validation. Return to Hex and allow screen control again."
    case MCPClientSessionError.requestTimedOut:
      message = "Screen control did not respond in time. Try again."
    case MCPClientSessionError.limitExceeded, MCPClientSessionError.protocolViolation:
      message =
        "Screen control returned an invalid permission response. Restart Hex Agent and try again."
    default:
      message = "Hex Agent could not verify screen control. Restart Hex Agent and try again."
    }

    return GatewayFailure(
      code: .transportUnavailable,
      message: message,
      isRetryable: true
    )
  }
}
