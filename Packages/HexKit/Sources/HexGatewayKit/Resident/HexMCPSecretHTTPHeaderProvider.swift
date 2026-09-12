import Foundation
import HexCore
import HexMCP

/// Resolves one endpoint-bound credential immediately before a request. Never caches a token.
public struct HexMCPSecretHTTPHeaderProvider: MCPHTTPHeaderProvider {
  private let serverID: String
  private let key: HexSecretKey
  private let secretStore: any HexSecretStore

  public init(serverID: String, endpointURL: URL, secretStore: any HexSecretStore) throws {
    self.serverID = serverID
    key = try .mcpBearerToken(serverID: serverID, endpointURL: endpointURL)
    self.secretStore = secretStore
  }

  public func headers(for serverID: String) async throws -> [String: String] {
    try Task.checkCancellation()
    guard serverID == self.serverID else { throw MCPClientSessionError.authenticationRejected }
    let token: String
    do {
      token = try await secretStore.secret(for: key)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // Keychain errors and arbitrary injected-store messages must not enter runtime diagnostics.
      throw MCPClientSessionError.authenticationRejected
    }
    try Task.checkCancellation()
    guard !token.isEmpty, token.utf8.count <= 16 * 1_024 - 7,
      token.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else { throw MCPClientSessionError.authenticationRejected }
    return ["Authorization": "Bearer \(token)"]
  }
}
