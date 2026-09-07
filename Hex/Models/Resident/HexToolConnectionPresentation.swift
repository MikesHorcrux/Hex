import HexCore
import HexIPC

/// Only vetted local strings become action guidance; server errors are never rendered verbatim.
nonisolated struct HexToolConnectionPresentation {
  let status: GatewayToolServerStatus

  var name: String {
    switch status.transport {
    case .playwright: "Browser control"
    case .peekaboo: "Screen control"
    case .xcode: "Xcode control"
    case .streamableHTTP, nil: status.serverID
    }
  }

  var title: String {
    switch status.state {
    case .ready:
      if let count = status.availableToolCount {
        "Connected · \(count) \(count == 1 ? "tool" : "tools")"
      } else {
        "Connected"
      }
    case .disconnected: "Not started"
    case .connecting: "Connecting"
    case .unavailable: "Needs attention"
    }
  }

  var actionTitle: String {
    status.state == .unavailable ? "Retry connection" : "Check connection"
  }

  var detail: String? {
    if let failure = status.failure {
      return switch failure {
      case .componentMissing:
        status.transport == .xcode
          ? "Open Xcode and your project, check that Xcode's tool access is enabled, then retry."
          : status.transport == .playwright || status.transport == .peekaboo
            ? "A component is missing. In Built-in tools below, turn this tool off and back on to retry installation. Wait for setup to finish, then save and retry the connection."
            : "A component is missing. Check this server's installation and saved settings, then retry."
      case .configurationInvalid:
        "Check this tool's saved settings below, save the changes, then retry the connection."
      case .connectionTimedOut:
        "The tool did not respond in time. Check that it is available, then retry the connection."
      case .serverRejected:
        "The tool server refused the connection. Check its access settings, then retry."
      case .invalidResponse:
        "The tool server returned an unsupported response. Check its version or settings, then retry."
      case .connectionFailed:
        status.transport == .xcode
          ? "Open Xcode and your project, check that Xcode's tool access is enabled, then retry."
          : "Hex could not connect to this tool. Check its availability and saved settings, then retry."
      }
    }
    return switch status.state {
    case .disconnected:
      "This enabled tool has not connected yet. Check it now, or Hex will try when needed."
    case .connecting:
      "The resident is starting or reconnecting this tool. Refresh status to check its progress."
    case .ready: nil
    case .unavailable: "This tool is not available to the running agent. Retry its connection."
    }
  }
}
