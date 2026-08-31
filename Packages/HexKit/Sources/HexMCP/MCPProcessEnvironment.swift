import Foundation

public enum MCPProcessEnvironment {
  public static func sanitized(
    from source: [String: String] = ProcessInfo.processInfo.environment,
    overrides: [String: String] = [:]
  ) throws -> [String: String] {
    let allowedNames = [
      "DEVELOPER_DIR",
      "HOME",
      "LANG",
      "LC_ALL",
      "LC_CTYPE",
      "LOGNAME",
      "MCP_XCODE_PID",
      "MCP_XCODE_SESSION_ID",
      "PATH",
      "SHELL",
      "TMPDIR",
      "TOOLCHAINS",
      "USER",
    ]
    let allowedSet = Set(allowedNames)
    guard overrides.keys.allSatisfy(allowedSet.contains) else {
      throw MCPServerConfigurationError.invalidEnvironment
    }
    var result: [String: String] = [:]
    for name in allowedNames {
      if let value = overrides[name] ?? source[name] {
        result[name] = value
      }
    }
    if result["PATH"] == nil {
      result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    }
    return result
  }
}
