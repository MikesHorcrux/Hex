import Foundation

extension MCPServerConfiguration {
  public static func peekaboo(
    layout: MCPManagedToolLayout,
    workspaceRoot: URL,
    sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> MCPServerConfiguration {
    try layout.validate(.peekaboo)
    let environment = try MCPProcessEnvironment.sanitized(from: sourceEnvironment)
    return try MCPServerConfiguration(
      serverID: "peekaboo",
      executableURL: layout.peekabooExecutableURL,
      arguments: ["mcp", "serve", "--input-strategy", "actionFirst"],
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
