import Foundation
import HexCore
import HexMCP
import Testing

@testable import HexGatewayKit

@Suite("Request-time MCP credential resolution")
struct HexMCPSecretHTTPHeaderProviderTests {
  @Test
  func retrievesCurrentTokenForEachRequestAndRejectsAnotherServer() async throws {
    let endpoint = try #require(URL(string: "http://127.0.0.1:8123/mcp"))
    let key = try HexSecretKey.mcpBearerToken(serverID: "docs", endpointURL: endpoint)
    let store = Store()
    let provider = try HexMCPSecretHTTPHeaderProvider(
      serverID: "docs", endpointURL: endpoint, secretStore: store)
    #expect(await store.reads == 0)
    try await store.save("synthetic-first", for: key)
    #expect(try await provider.headers(for: "docs") == ["Authorization": "Bearer synthetic-first"])
    try await store.save("synthetic-second", for: key)
    #expect(try await provider.headers(for: "docs") == ["Authorization": "Bearer synthetic-second"])
    await #expect(throws: MCPClientSessionError.authenticationRejected) {
      try await provider.headers(for: "other")
    }
    #expect(await store.reads == 2)
  }

  @Test
  func absentDeletedAndInvalidTokensFailClosed() async throws {
    let endpoint = try #require(URL(string: "http://127.0.0.1:8123/mcp"))
    let key = try HexSecretKey.mcpBearerToken(serverID: "docs", endpointURL: endpoint)
    let store = Store()
    let provider = try HexMCPSecretHTTPHeaderProvider(
      serverID: "docs", endpointURL: endpoint, secretStore: store)
    await #expect(throws: MCPClientSessionError.authenticationRejected) {
      try await provider.headers(for: "docs")
    }
    for token in ["", "token\r\nX-Secret: injected", String(repeating: "a", count: 16 * 1_024)] {
      try await store.save(token, for: key)
      await #expect(throws: MCPClientSessionError.authenticationRejected) {
        try await provider.headers(for: "docs")
      }
    }
    try await store.delete(key)
    await #expect(throws: MCPClientSessionError.authenticationRejected) {
      try await provider.headers(for: "docs")
    }
  }

  private actor Store: HexSecretStore {
    private var values: [HexSecretKey: String] = [:]
    private(set) var reads = 0
    func secret(for key: HexSecretKey) async throws -> String {
      reads += 1
      guard let value = values[key] else { throw Missing.value }
      return value
    }
    func exists(_ key: HexSecretKey) async throws -> Bool { values[key] != nil }
    func save(_ secret: String, for key: HexSecretKey) async throws { values[key] = secret }
    func delete(_ key: HexSecretKey) async throws { values.removeValue(forKey: key) }
  }

  private enum Missing: Error { case value }
}
