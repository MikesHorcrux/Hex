import Foundation

public enum MCPManagedToolLayoutError: Error, Equatable, LocalizedError, Sendable {
  case invalidRoot
  case invalidInstallation(MCPManagedTool)

  public var errorDescription: String? {
    switch self {
    case .invalidRoot:
      "The managed MCP tools root is invalid."
    case .invalidInstallation(let tool):
      "The managed \(tool.rawValue) installation is missing or invalid."
    }
  }
}
