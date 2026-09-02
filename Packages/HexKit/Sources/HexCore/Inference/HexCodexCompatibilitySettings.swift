import Foundation

/// Non-secret launch settings for the Codex app-server compatibility mode.
///
/// The executable is never downloaded or installed by Hex. `nil` means the compatibility backend
/// has not been configured yet. The app-server command and its protocol remain owned by the
/// provider layer; these settings only select an already-existing executable and working folder.
public struct HexCodexCompatibilitySettings: Codable, Equatable, Sendable {
  public let executableURL: URL?
  public let workingDirectoryURL: URL?

  public init(
    executableURL: URL? = nil,
    workingDirectoryURL: URL? = nil
  ) throws {
    if let executableURL {
      guard Self.isValidAbsoluteFileURL(executableURL) else {
        throw HexInferenceBackendSettingsError.invalidCodexExecutable
      }
    }
    if let workingDirectoryURL {
      guard Self.isValidAbsoluteFileURL(workingDirectoryURL) else {
        throw HexInferenceBackendSettingsError.invalidCodexWorkingDirectory
      }
    }
    self.executableURL = executableURL?.standardizedFileURL
    self.workingDirectoryURL = workingDirectoryURL?.standardizedFileURL
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      executableURL: container.decodeIfPresent(URL.self, forKey: .executableURL),
      workingDirectoryURL: container.decodeIfPresent(URL.self, forKey: .workingDirectoryURL)
    )
  }

  public var isConfigured: Bool {
    executableURL != nil
  }

  private enum CodingKeys: String, CodingKey {
    case executableURL
    case workingDirectoryURL
  }

  private static func isValidAbsoluteFileURL(_ url: URL) -> Bool {
    let path = url.path
    return url.isFileURL
      && !path.isEmpty
      && path != "/"
      && path.hasPrefix("/")
      && path.utf8.count <= 4_096
      && !path.contains("\0")
  }
}
