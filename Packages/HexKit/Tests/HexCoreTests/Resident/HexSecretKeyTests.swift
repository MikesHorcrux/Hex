import Foundation
import HexCore
import Testing

@Suite("Endpoint-bound MCP secret identity")
struct HexSecretKeyTests {
  @Test
  func existingProviderKeysKeepTheirPersistedIdentity() throws {
    for raw in ["openai-api-key", "openai-chatgpt-oauth"] {
      let data = try JSONEncoder().encode(raw)
      let key = try JSONDecoder().decode(HexSecretKey.self, from: data)
      #expect(key.rawValue == raw)
      #expect(try JSONEncoder().encode(key) == data)
    }
    #expect(HexSecretKey(rawValue: "arbitrary-key") == nil)
    #expect(HexSecretKey(rawValue: "mcp-bearer-short") == nil)
  }

  @Test
  func endpointPathPortAndServerIdentityNeverShareCredentials() throws {
    let original = try #require(URL(string: "http://127.0.0.1:8123/mcp"))
    let key = try HexSecretKey.mcpBearerToken(serverID: "docs", endpointURL: original)
    #expect(key == (try .mcpBearerToken(serverID: "docs", endpointURL: original)))
    #expect(key != (try .mcpBearerToken(serverID: "other", endpointURL: original)))
    for address in [
      "http://127.0.0.1:8124/mcp", "http://127.0.0.1:8123/other", "https://127.0.0.1:8123/mcp",
    ] {
      let endpoint = try #require(URL(string: address))
      #expect(key != (try .mcpBearerToken(serverID: "docs", endpointURL: endpoint)))
    }
    #expect(!key.rawValue.contains("127.0.0.1"))
    #expect(try JSONDecoder().decode(HexSecretKey.self, from: JSONEncoder().encode(key)) == key)
  }
}
