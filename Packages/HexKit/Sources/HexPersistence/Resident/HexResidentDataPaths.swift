import Foundation

/// The resident gateway's non-secret settings, journal, and heartbeat locations.
public struct HexResidentDataPaths: Equatable, Sendable {
  public let directoryURL: URL
  public let settingsURL: URL
  public let databaseURL: URL
  public let heartbeatStoreURL: URL
  public let personalityProfileURL: URL
  public let personalMemoryURL: URL

  /// Creates the conventional resident paths beneath an Application Support directory.
  public init(applicationSupportURL: URL) throws {
    guard Self.isAbsoluteDirectoryURL(applicationSupportURL) else {
      throw HexResidentDataPathsPathError.invalidApplicationSupportURL
    }
    let directoryURL = applicationSupportURL
      .standardizedFileURL
      .appendingPathComponent("Hex", isDirectory: true)
    try self.init(
      settingsURL: directoryURL.appendingPathComponent(
        "resident-settings.json", isDirectory: false),
      databaseURL: directoryURL.appendingPathComponent("agent-events.sqlite", isDirectory: false),
      heartbeatStoreURL: directoryURL.appendingPathComponent("heartbeats.json", isDirectory: false),
      personalityProfileURL: directoryURL.appendingPathComponent(
        "personality-profile.json", isDirectory: false),
      personalMemoryURL: directoryURL.appendingPathComponent(
        "personal-memory.json", isDirectory: false)
    )
  }

  /// Creates explicit paths for tests or a caller that owns its persistence directory.
  public init(
    settingsURL: URL,
    databaseURL: URL,
    heartbeatStoreURL: URL,
    personalityProfileURL: URL? = nil,
    personalMemoryURL: URL? = nil
  ) throws {
    let directoryURL = settingsURL.standardizedFileURL.deletingLastPathComponent()
    let resolvedPersonalityProfileURL =
      personalityProfileURL
      ?? directoryURL.appendingPathComponent("personality-profile.json", isDirectory: false)
    let resolvedPersonalMemoryURL =
      personalMemoryURL
      ?? directoryURL.appendingPathComponent("personal-memory.json", isDirectory: false)
    guard
      Self.isAbsoluteFileURL(settingsURL),
      Self.isAbsoluteFileURL(databaseURL),
      Self.isAbsoluteFileURL(heartbeatStoreURL),
      Self.isAbsoluteFileURL(resolvedPersonalityProfileURL),
      Self.isAbsoluteFileURL(resolvedPersonalMemoryURL)
    else {
      throw HexResidentDataPathsPathError.invalidDataURL
    }

    self.settingsURL = settingsURL.standardizedFileURL
    self.databaseURL = databaseURL.standardizedFileURL
    self.heartbeatStoreURL = heartbeatStoreURL.standardizedFileURL
    self.personalityProfileURL = resolvedPersonalityProfileURL.standardizedFileURL
    self.personalMemoryURL = resolvedPersonalMemoryURL.standardizedFileURL
    self.directoryURL = self.settingsURL.deletingLastPathComponent()
  }

  /// Resolves the user's Application Support directory at the point the resident gateway starts.
  public static func live() throws -> Self {
    guard
      let applicationSupportURL = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw HexResidentDataPathsPathError.applicationSupportUnavailable
    }
    return try Self(applicationSupportURL: applicationSupportURL)
  }

  private static func isAbsoluteDirectoryURL(_ url: URL) -> Bool {
    isAbsoluteFileURL(url) && !url.path.isEmpty
  }

  private static func isAbsoluteFileURL(_ url: URL) -> Bool {
    let path = url.path
    guard
      url.isFileURL,
      !path.isEmpty,
      path.hasPrefix("/"),
      path.utf8.count <= 4_096,
      !path.contains("\0")
    else {
      return false
    }
    let lastPathComponent = url.lastPathComponent
    return !lastPathComponent.isEmpty && lastPathComponent != "." && lastPathComponent != ".."
  }
}
