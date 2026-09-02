import Darwin
import Foundation

/// Versioned, non-secret locations for optional MCP runtimes installed outside Hex.app.
///
/// Keeping these dependencies in Application Support avoids importing another agent runtime into
/// Hex or adding Node packages to the Swift dependency graph. Every executable still crosses the
/// bounded MCP process snapshot before it can expose tools to the agent loop.
public struct MCPManagedToolLayout: Equatable, Sendable {
  public static let nodeVersion = "24.20.0"
  public static let playwrightVersion = "0.0.80"
  public static let playwrightBrowserRevision = "1243"
  public static let peekabooVersion = "4.2.2"

  public let rootURL: URL

  public init(rootURL: URL) throws {
    guard Self.isAbsoluteFileURL(rootURL), rootURL.path != "/" else {
      throw MCPManagedToolLayoutError.invalidRoot
    }
    self.rootURL = rootURL.standardizedFileURL
  }

  public var nodeExecutableURL: URL {
    rootURL
      .appendingPathComponent("node", isDirectory: true)
      .appendingPathComponent(Self.nodeVersion, isDirectory: true)
      .appendingPathComponent("bin/node", isDirectory: false)
  }

  public var playwrightInstallationURL: URL {
    rootURL
      .appendingPathComponent("playwright-mcp", isDirectory: true)
      .appendingPathComponent(Self.playwrightVersion, isDirectory: true)
  }

  public var playwrightServerScriptURL: URL {
    playwrightInstallationURL.appendingPathComponent(
      "node_modules/@playwright/mcp/cli.js",
      isDirectory: false
    )
  }

  public var playwrightPackageManifestURL: URL {
    playwrightInstallationURL.appendingPathComponent(
      "node_modules/@playwright/mcp/package.json",
      isDirectory: false
    )
  }

  public var playwrightBrowsersURL: URL {
    playwrightInstallationURL.appendingPathComponent("browsers", isDirectory: true)
  }

  public var playwrightBrowserExecutableURL: URL {
    playwrightBrowsersURL
      .appendingPathComponent(
        "chromium-\(Self.playwrightBrowserRevision)",
        isDirectory: true
      )
      .appendingPathComponent("chrome-mac-arm64", isDirectory: true)
      .appendingPathComponent("Google Chrome for Testing.app", isDirectory: true)
      .appendingPathComponent("Contents/MacOS/Google Chrome for Testing", isDirectory: false)
  }

  public var playwrightOutputURL: URL {
    playwrightInstallationURL.appendingPathComponent("output", isDirectory: true)
  }

  public var peekabooInstallationURL: URL {
    rootURL
      .appendingPathComponent("peekaboo", isDirectory: true)
      .appendingPathComponent(Self.peekabooVersion, isDirectory: true)
      .appendingPathComponent("peekaboo-macos-universal", isDirectory: true)
  }

  public var peekabooExecutableURL: URL {
    peekabooInstallationURL
      .appendingPathComponent("PeekabooCLI.app", isDirectory: true)
      .appendingPathComponent("Contents/MacOS/peekaboo", isDirectory: false)
  }

  public var peekabooVersionFileURL: URL {
    peekabooInstallationURL.appendingPathComponent("VERSION", isDirectory: false)
  }

  public func availability(for tool: MCPManagedTool) -> MCPManagedToolAvailability {
    do {
      try validate(tool)
      return .ready
    } catch {
      return .unavailable
    }
  }

  public func validate(_ tool: MCPManagedTool) throws {
    let isValid =
      switch tool {
      case .playwright:
        isSafeRegularFile(nodeExecutableURL, requiresExecute: true)
          && isSafeRegularFile(playwrightServerScriptURL, requiresExecute: false)
          && isSafeRegularFile(playwrightBrowserExecutableURL, requiresExecute: true)
          && hasExpectedPlaywrightManifest()
      case .peekaboo:
        isSafeRegularFile(peekabooExecutableURL, requiresExecute: true)
          && hasExpectedPeekabooVersion()
      }
    guard isValid else {
      throw MCPManagedToolLayoutError.invalidInstallation(tool)
    }
  }

  private func hasExpectedPlaywrightManifest() -> Bool {
    guard
      isSafeRegularFile(playwrightPackageManifestURL, requiresExecute: false),
      let data = try? Data(contentsOf: playwrightPackageManifestURL, options: [.mappedIfSafe]),
      data.count <= 64 * 1_024,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return false
    }
    return object["name"] as? String == "@playwright/mcp"
      && object["version"] as? String == Self.playwrightVersion
      && object["license"] as? String == "Apache-2.0"
  }

  private func hasExpectedPeekabooVersion() -> Bool {
    guard
      isSafeRegularFile(peekabooVersionFileURL, requiresExecute: false),
      let data = try? Data(contentsOf: peekabooVersionFileURL, options: [.mappedIfSafe]),
      data.count <= 128,
      let value = String(data: data, encoding: .utf8)
    else {
      return false
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines) == Self.peekabooVersion
  }

  private func isSafeRegularFile(_ url: URL, requiresExecute: Bool) -> Bool {
    var status = stat()
    guard
      lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid() || status.st_uid == 0,
      status.st_nlink == 1,
      status.st_size > 0,
      status.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
    else {
      return false
    }
    if requiresExecute {
      return status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }
    return true
  }

  private static func isAbsoluteFileURL(_ url: URL) -> Bool {
    url.isFileURL
      && url.path.hasPrefix("/")
      && !url.path.contains("\0")
      && url.path.utf8.count <= 4_096
  }
}
