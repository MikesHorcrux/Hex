import Foundation

public enum GatewayFolderAccessMode: String, Codable, Sendable {
  case readable
  case denied
  case unavailable
}
