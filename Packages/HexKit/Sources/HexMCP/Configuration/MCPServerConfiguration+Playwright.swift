import Foundation

extension MCPServerConfiguration {
  public static func playwright(
    layout: MCPManagedToolLayout,
    workspaceRoot: URL,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> MCPServerConfiguration {
    try layout.validate(.playwright)
    guard workspaceRoot.isFileURL, workspaceRoot.path.hasPrefix("/") else {
      throw MCPServerConfigurationError.invalidWorkingDirectory
    }
    do {
      try FileManager.default.createDirectory(
        at: layout.playwrightOutputURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw MCPServerConfigurationError.invalidWorkingDirectory
    }
    let environment = try MCPProcessEnvironment.sanitized(
      from: sourceEnvironment,
      overrides: ["PLAYWRIGHT_BROWSERS_PATH": layout.playwrightBrowsersURL.path]
    )
    return try MCPServerConfiguration(
      serverID: "playwright",
      executableURL: layout.nodeExecutableURL,
      arguments: [
        layout.playwrightServerScriptURL.path,
        "--isolated",
        "--output-dir",
        layout.playwrightOutputURL.path,
        "--output-max-size",
        "52428800",
        "--codegen",
        "none",
      ],
      workingDirectory: workspaceRoot,
      environment: environment,
      requestTimeoutMilliseconds: 120_000,
      shutdownGraceMilliseconds: 1_000,
      maximumStderrBytes: 256 * 1_024,
      maximumToolPages: 8,
      maximumTools: 256
    )
  }
}
