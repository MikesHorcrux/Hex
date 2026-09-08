import Foundation
import HexCore
import Testing

@Suite("Persisted custom MCP settings")
struct HexMCPConnectionSettingsTests {
  @Test
  func legacyHTTPDefaultsToNoCredentialAndPreservesReservedIdentity() throws {
    let data = Data(
      #"{"serverID":"playwright","transport":"streamableHTTP","endpointURL":"http://127.0.0.1:8123/mcp","isEnabled":true}"#
        .utf8)
    let settings = try JSONDecoder().decode(HexResidentMCPServerSettings.self, from: data)
    #expect(!settings.requiresBearerToken)
    #expect(settings.executableURL == nil)
    #expect(settings.arguments.isEmpty)
    #expect(settings.transport == .streamableHTTP)
  }

  @Test
  func explicitArgumentsRoundTripWithoutShellParsing() throws {
    let settings = try HexResidentMCPServerSettings(
      serverID: "local_docs", transport: .stdio,
      executableURL: URL(fileURLWithPath: "/usr/bin/awk"),
      arguments: ["a b", "", "$(not-a-shell-command)"],
      workingDirectory: URL(fileURLWithPath: "/tmp"))
    let encoded = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(HexResidentMCPServerSettings.self, from: encoded) == settings)
  }

  @Test
  func rejectsCrossTransportFieldsAndUnboundedArguments() throws {
    let endpoint = try #require(URL(string: "http://127.0.0.1:8123/mcp"))
    let executable = URL(fileURLWithPath: "/usr/bin/awk")
    let directory = URL(fileURLWithPath: "/tmp")
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      try HexResidentMCPServerSettings(
        serverID: "local_docs", transport: .streamableHTTP, endpointURL: endpoint,
        executableURL: executable)
    }
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      try HexResidentMCPServerSettings(
        serverID: "local_docs", transport: .stdio, requiresBearerToken: true,
        executableURL: executable, workingDirectory: directory)
    }
    for arguments in [
      [String(repeating: "a", count: 65_537)], Array(repeating: "a", count: 257), ["a\0b"],
    ] {
      #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
        try HexResidentMCPServerSettings(
          serverID: "local_docs", transport: .stdio, executableURL: executable,
          arguments: arguments, workingDirectory: directory)
      }
    }
    #expect(throws: HexResidentRuntimeSettingsError.invalidMCPServers) {
      try HexResidentMCPServerSettings(
        serverID: "playwright", transport: .stdio, executableURL: executable,
        workingDirectory: directory)
    }
  }
}
