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

  @Test("Public configurations reject secret-bearing environment variables")
  func publicConfigurationRejectsUnallowlistedEnvironment() {
    #expect(throws: MCPServerConfigurationError.invalidEnvironment) {
      try MCPServerConfiguration(
        serverID: "fixture",
        executableURL: URL(fileURLWithPath: "/usr/bin/true"),
        arguments: [],
        workingDirectory: URL(fileURLWithPath: "/"),
        environment: ["OPENAI_API_KEY": "should-never-reach-spawn"]
      )
    }
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

  @Test("Creates pinned Playwright and Peekaboo configurations without ambient credentials")
  func createsManagedToolConfigurations() throws {
    let installation = try makeManagedToolInstallation()
    defer { try? FileManager.default.removeItem(at: installation.rootURL) }
    let workspace = installation.rootURL.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)

    let playwright = try MCPServerConfiguration.playwright(
      layout: installation.layout,
      workspaceRoot: workspace,
      sourceEnvironment: [
        "HOME": "/Users/example",
        "OPENAI_API_KEY": "must-not-cross-the-boundary",
      ]
    )
    let peekaboo = try MCPServerConfiguration.peekaboo(
      layout: installation.layout,
      workspaceRoot: workspace,
      sourceEnvironment: [
        "HOME": "/Users/example",
        "OPENAI_API_KEY": "must-not-cross-the-boundary",
      ]
    )

    #expect(playwright.serverID == "playwright")
    #expect(playwright.executableURL == installation.layout.nodeExecutableURL)
    #expect(playwright.arguments.first == installation.layout.playwrightServerScriptURL.path)
    #expect(
      playwright.environment["PLAYWRIGHT_BROWSERS_PATH"]
        == installation.layout.playwrightBrowsersURL.path
    )
    #expect(playwright.environment["OPENAI_API_KEY"] == nil)
    #expect(peekaboo.serverID == "peekaboo")
    #expect(peekaboo.executableURL == installation.layout.peekabooExecutableURL)
    #expect(peekaboo.arguments == ["mcp", "serve", "--input-strategy", "actionFirst"])
    #expect(peekaboo.environment["OPENAI_API_KEY"] == nil)
  }

  @Test("Rejects incomplete managed tool installations")
  func rejectsIncompleteManagedToolInstallations() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexManagedTools-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let layout = try MCPManagedToolLayout(rootURL: rootURL)

    #expect(layout.availability(for: .playwright) == .unavailable)
    #expect(layout.availability(for: .peekaboo) == .unavailable)
    #expect(throws: MCPManagedToolLayoutError.invalidInstallation(.playwright)) {
      try layout.validate(.playwright)
    }
    #expect(throws: MCPManagedToolLayoutError.invalidInstallation(.peekaboo)) {
      try layout.validate(.peekaboo)
    }
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

  @Test("Exposes validated persistent snapshot admission limits")
  func exposesSnapshotAdmissionPolicy() throws {
    let policy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 4,
      maximumEntriesPerSlot: 8,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 1_024
    )
    let configuration = try MCPServerConfiguration(
      serverID: "fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/true"),
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: [:],
      executableSnapshotPolicy: policy
    )

    #expect(configuration.executableSnapshotPolicy == policy)
    #expect(policy.maximumTotalRetainedEntries == 32)
    #expect(policy.maximumTotalPathMetadataBytes == 16_384)
    #expect(policy.maximumTotalCopiedBytes == 4_096)
    #expect(MCPExecutableSnapshotPolicy.standard.maximumRetainedSlots == 32)
    #expect(MCPExecutableSnapshotPolicy.standard.maximumTotalRetainedEntries == 65_536)
    #expect(
      MCPExecutableSnapshotPolicy.standard.maximumTotalPathMetadataBytes
        == 256 * 1_024 * 1_024
    )
    #expect(
      MCPExecutableSnapshotPolicy.standard.maximumTotalCopiedBytes
        == 4 * 1_024 * 1_024 * 1_024
    )
    #expect(throws: MCPExecutableSnapshotPolicyError.invalidLimit) {
      _ = try MCPExecutableSnapshotPolicy(
        maximumRetainedSlots: 4_097,
        maximumEntriesPerSlot: 8,
        maximumPathMetadataBytesPerSlot: 4_096,
        maximumCopiedBytesPerSlot: 1_024
      )
    }
  }

  private func makeManagedToolInstallation() throws -> (
    rootURL: URL,
    layout: MCPManagedToolLayout
  ) {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexManagedTools-\(UUID().uuidString)",
      isDirectory: true
    )
    let layout = try MCPManagedToolLayout(rootURL: rootURL)
    try writeFixture("node", to: layout.nodeExecutableURL, executable: true)
    try writeFixture("#!/usr/bin/env node", to: layout.playwrightServerScriptURL)
    let packageData = try JSONSerialization.data(
      withJSONObject: [
        "name": "@playwright/mcp",
        "version": MCPManagedToolLayout.playwrightVersion,
        "license": "Apache-2.0",
      ],
      options: [.sortedKeys]
    )
    try writeFixture(packageData, to: layout.playwrightPackageManifestURL)
    try writeFixture("browser", to: layout.playwrightBrowserExecutableURL, executable: true)
    try writeFixture("peekaboo", to: layout.peekabooExecutableURL, executable: true)
    try writeFixture(
      MCPManagedToolLayout.peekabooVersion,
      to: layout.peekabooVersionFileURL
    )
    return (rootURL, layout)
  }

  private func writeFixture(
    _ value: String,
    to url: URL,
    executable: Bool = false
  ) throws {
    try writeFixture(Data(value.utf8), to: url, executable: executable)
  }

  private func writeFixture(
    _ data: Data,
    to url: URL,
    executable: Bool = false
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
    if executable {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
      )
    }
  }
}
