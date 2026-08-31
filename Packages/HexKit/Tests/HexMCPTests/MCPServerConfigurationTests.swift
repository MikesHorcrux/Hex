import Foundation
import Testing

@testable import HexMCP

@Suite("MCP server configuration")
struct MCPServerConfigurationTests {
  @Test("Sanitized environments exclude ambient credentials")
  func sanitizedEnvironmentExcludesCredentials() throws {
    let environment = try MCPProcessEnvironment.sanitized(
      from: [
        "HOME": "/Users/example",
        "PATH": "/usr/bin:/bin",
        "OPENAI_API_KEY": "TOP_SECRET_OPENAI_KEY",
        "AWS_SECRET_ACCESS_KEY": "TOP_SECRET_AWS_KEY",
        "SSH_AUTH_SOCK": "/tmp/agent.sock",
      ]
    )

    #expect(environment["HOME"] == "/Users/example")
    #expect(environment["PATH"] == "/usr/bin:/bin")
    #expect(environment["OPENAI_API_KEY"] == nil)
    #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    #expect(environment["SSH_AUTH_SOCK"] == nil)
  }

  @Test("Xcode factory resolves the local bridge without starting it")
  func createsInertXcodeConfiguration() throws {
    let sessionID = "9F3D9682-3DCA-4FE2-A9FB-7AB03A35E61B"
    let configuration = try MCPServerConfiguration.xcode(
      sourceEnvironment: ["PATH": "/usr/bin:/bin"],
      developerDirectory: URL(
        fileURLWithPath: "/Applications/Xcode.app/Contents/Developer",
        isDirectory: true
      ),
      xcodeProcessID: "1234",
      xcodeSessionID: sessionID
    )

    #expect(configuration.serverID == "xcode")
    #expect(
      configuration.executableURL.path
        == "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge"
    )
    #expect(configuration.arguments.isEmpty)
    #expect(
      configuration.environment["DEVELOPER_DIR"]
        == "/Applications/Xcode.app/Contents/Developer"
    )
    #expect(configuration.environment["MCP_XCODE_PID"] == "1234")
    #expect(configuration.environment["MCP_XCODE_SESSION_ID"] == sessionID)
  }

  @Test("Rejects invalid explicit Xcode routing values")
  func rejectsInvalidXcodeRoutingValues() {
    #expect(throws: MCPServerConfigurationError.invalidEnvironment) {
      try MCPServerConfiguration.xcode(
        developerDirectory: URL(
          fileURLWithPath: "/Applications/Xcode.app/Contents/Developer",
          isDirectory: true
        ),
        xcodeProcessID: "0"
      )
    }
    #expect(throws: MCPServerConfigurationError.invalidEnvironment) {
      try MCPServerConfiguration.xcode(
        developerDirectory: URL(
          fileURLWithPath: "/Applications/Xcode.app/Contents/Developer",
          isDirectory: true
        ),
        xcodeSessionID: "not-a-uuid"
      )
    }
    #expect(throws: MCPServerConfigurationError.invalidEnvironment) {
      try MCPServerConfiguration.xcode(
        sourceEnvironment: [
          "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
          "MCP_XCODE_PID": "not-a-pid",
        ]
      )
    }
  }

  @Test("Rejects relative executables, invalid environment names, and unbounded limits")
  func rejectsInvalidBoundaries() throws {
    let relativeExecutable = try #require(URL(string: "relative-tool"))
    #expect(throws: MCPServerConfigurationError.invalidExecutable) {
      try MCPServerConfiguration(
        serverID: "fixture",
        executableURL: relativeExecutable,
        arguments: [],
        workingDirectory: URL(fileURLWithPath: "/"),
        environment: [:]
      )
    }
    #expect(throws: MCPServerConfigurationError.invalidEnvironment) {
      try MCPServerConfiguration(
        serverID: "fixture",
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        workingDirectory: URL(fileURLWithPath: "/"),
        environment: ["BAD=NAME": "value"]
      )
    }
    #expect(throws: MCPServerConfigurationError.invalidLimit) {
      try MCPServerConfiguration(
        serverID: "fixture",
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        workingDirectory: URL(fileURLWithPath: "/"),
        environment: [:],
        maximumMessageBytes: Int.max
      )
    }
  }
}
