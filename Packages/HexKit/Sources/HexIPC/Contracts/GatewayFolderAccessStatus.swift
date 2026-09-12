import Foundation

/// An actual directory read in the resident process, not a claim of Full Disk Access.
public struct GatewayFolderAccessStatus: Codable, Equatable, Sendable {
  public enum Access: String, Codable, Sendable {
    case readable
    case denied
    case unavailable
  }

  public let directory: URL
  public let agentBundle: URL
  public let access: Access

  public init(directory: URL, agentBundle: URL, access: Access) {
    self.directory = directory
    self.agentBundle = agentBundle
    self.access = access
  }

  public func validated() throws -> Self {
    guard directory.isFileURL, agentBundle.isFileURL,
      directory.path.hasPrefix("/"), agentBundle.path.hasPrefix("/"),
      directory.path.utf8.count <= 16_384, agentBundle.path.utf8.count <= 16_384
    else {
      throw GatewayFailure(code: .malformedPayload, message: "The folder access result is invalid.")
    }
    return self
  }
}
