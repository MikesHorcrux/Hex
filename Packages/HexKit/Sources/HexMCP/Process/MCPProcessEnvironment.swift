import Foundation

public enum MCPProcessEnvironment {
  private static let allowedNames = [
    "DEVELOPER_DIR",
    "HOME",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "LOGNAME",
    "MCP_XCODE_PID",
    "MCP_XCODE_SESSION_ID",
    "NPM_CONFIG_CACHE",
    "PATH",
    "PLAYWRIGHT_BROWSERS_PATH",
    "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD",
    "SHELL",
    "TMPDIR",
    "TOOLCHAINS",
    "USER",
  ]
  private static let allowedNameSet = Set(allowedNames)

  public static func sanitized(
    from source: [String: String] = ProcessInfo.processInfo.environment,
    overrides: [String: String] = [:]
  ) throws -> [String: String] {
    guard overrides.keys.allSatisfy(allowedNameSet.contains) else {
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

  static func validatedExplicit(_ values: [String: String]) throws -> [String: String] {
    guard values.keys.allSatisfy(allowedNameSet.contains) else {
      throw MCPServerConfigurationError.invalidEnvironment
    }
    return values
  }
}
