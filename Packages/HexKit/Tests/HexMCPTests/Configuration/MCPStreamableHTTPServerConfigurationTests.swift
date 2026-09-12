import Foundation
import Testing

@testable import HexMCP

@Suite("MCP Streamable HTTP configuration")
struct MCPStreamableHTTPServerConfigurationTests {
  @Test
  func acceptsHTTPSAndLiteralLoopbackHTTP() throws {
    let https = try MCPStreamableHTTPServerConfiguration(
      serverID: "remote",
      endpointURL: try #require(URL(string: "https://mcp.example.com/v1"))
    )
    let loopback = try MCPStreamableHTTPServerConfiguration(
      serverID: "local",
      endpointURL: try #require(URL(string: "http://127.0.0.1:8765/mcp"))
    )

    #expect(https.endpointURL.scheme == "https")
    #expect(loopback.endpointURL.host == "127.0.0.1")
  }

  @Test
  func rejectsRemotePlaintextCredentialsAndQueries() throws {
    for rawURL in [
      "http://example.com/mcp",
      "https://user:secret@example.com/mcp",
      "https://example.com/mcp?token=secret",
    ] {
      let url = try #require(URL(string: rawURL))
      #expect(throws: MCPServerConfigurationError.invalidEndpoint) {
        _ = try MCPStreamableHTTPServerConfiguration(
          serverID: "server",
          endpointURL: url
        )
      }
    }
  }
}
