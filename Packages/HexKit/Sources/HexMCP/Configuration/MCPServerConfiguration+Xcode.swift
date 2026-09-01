import Foundation

extension MCPServerConfiguration {
  public static func xcode(
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    developerDirectory: URL? = nil,
    xcodeProcessID: String? = nil,
    xcodeSessionID: String? = nil
  ) throws -> MCPServerConfiguration {
    let resolvedDeveloperDirectory = try resolveDeveloperDirectory(
      explicit: developerDirectory,
      sourceEnvironment: sourceEnvironment
    )
    let bridgeURL =
      resolvedDeveloperDirectory
      .appendingPathComponent("usr/bin/mcpbridge", isDirectory: false)
      .standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
      throw MCPServerConfigurationError.invalidExecutable
    }
    var overrides: [String: String] = [:]
    overrides["DEVELOPER_DIR"] = resolvedDeveloperDirectory.path
    if let xcodeProcessID {
      guard
        let processID = UInt32(xcodeProcessID),
        processID > 0,
        processID <= Int32.max
      else {
        throw MCPServerConfigurationError.invalidEnvironment
      }
      overrides["MCP_XCODE_PID"] = xcodeProcessID
    }
    if let xcodeSessionID {
      guard UUID(uuidString: xcodeSessionID) != nil else {
        throw MCPServerConfigurationError.invalidEnvironment
      }
      overrides["MCP_XCODE_SESSION_ID"] = xcodeSessionID
    }
    let environment = try MCPProcessEnvironment.sanitized(
      from: sourceEnvironment,
      overrides: overrides
    )
    guard validRoutingEnvironment(environment) else {
      throw MCPServerConfigurationError.invalidEnvironment
    }
    return try MCPServerConfiguration(
      serverID: "xcode",
      executableURL: bridgeURL,
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: environment
    )
  }

  private static func resolveDeveloperDirectory(
    explicit: URL?,
    sourceEnvironment: [String: String]
  ) throws -> URL {
    let candidate: URL
    if let explicit {
      candidate = explicit
    } else if let path = sourceEnvironment["DEVELOPER_DIR"] {
      candidate = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      candidate = URL(
        fileURLWithPath: "/Applications/Xcode.app/Contents/Developer",
        isDirectory: true
      )
    }
    guard
      candidate.isFileURL,
      candidate.path.hasPrefix("/"),
      !candidate.path.contains("\0"),
      candidate.path.utf8.count <= 4_096
    else {
      throw MCPServerConfigurationError.invalidExecutable
    }
    return candidate.standardizedFileURL
  }

  private static func validRoutingEnvironment(_ environment: [String: String]) -> Bool {
    if let value = environment["MCP_XCODE_PID"] {
      guard
        let processID = UInt32(value),
        processID > 0,
        processID <= Int32.max
      else {
        return false
      }
    }
    if let value = environment["MCP_XCODE_SESSION_ID"], UUID(uuidString: value) == nil {
      return false
    }
    return true
  }
}
