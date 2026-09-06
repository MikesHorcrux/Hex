import Foundation
import HexCore
import Hub

/// Downloads one immutable, flat MLX model manifest into Hex-owned storage.
public actor HuggingFaceMLXLocalModelInstaller: MLXLocalModelInstalling {
  typealias SnapshotDownloader =
    @Sendable (
      _ modelID: String,
      _ stagingRoot: URL,
      _ progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL

  private static let downloadPatterns = ["*.safetensors", "*.json", "*.jinja"]

  private let rootURL: URL
  private let downloadSnapshot: SnapshotDownloader

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
    downloadSnapshot = { modelID, stagingRoot, progress in
      let hub = HubApi(downloadBase: stagingRoot)
      return try await hub.snapshot(
        from: modelID,
        matching: Self.downloadPatterns
      ) { downloadProgress in
        progress(downloadProgress.fractionCompleted)
      }
    }
  }

  init(
    rootURL: URL,
    downloadSnapshot: @escaping SnapshotDownloader
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.downloadSnapshot = downloadSnapshot
  }

  public func install(
    modelID: String,
    progress: @Sendable @escaping (Double) -> Void
  ) async throws -> URL {
    let components = try Self.validatedComponents(for: modelID)
    try Self.validateRoot(rootURL)
    try Self.preparePrivateDirectory(rootURL)

    let destinationURL = components.reduce(rootURL) { partialURL, component in
      partialURL.appendingPathComponent(component, isDirectory: true)
    }
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard Self.isValidModelDirectory(destinationURL) else {
        throw MLXLocalModelInstallerError.existingModelIsInvalid
      }
      progress(1)
      return destinationURL
    }

    let stagingURL =
      rootURL
      .appendingPathComponent(".downloads", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try Self.preparePrivateDirectory(stagingURL)
    defer {
      try? FileManager.default.removeItem(at: stagingURL)
    }

    let downloadedURL = try await downloadSnapshot(modelID, stagingURL) { fraction in
      progress(min(max(fraction, 0), 1))
    }
    try Task.checkCancellation()
    guard Self.isDescendant(downloadedURL, of: stagingURL) else {
      throw MLXLocalModelInstallerError.invalidDownloadedModel
    }

    let metadataURL = downloadedURL.appendingPathComponent(".cache", isDirectory: true)
    if FileManager.default.fileExists(atPath: metadataURL.path) {
      try FileManager.default.removeItem(at: metadataURL)
    }
    guard Self.isValidModelDirectory(downloadedURL) else {
      throw MLXLocalModelInstallerError.invalidDownloadedModel
    }

    let destinationParentURL = destinationURL.deletingLastPathComponent()
    try Self.preparePrivateDirectory(destinationParentURL)
    do {
      try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
    } catch {
      guard Self.isValidModelDirectory(destinationURL) else {
        throw MLXLocalModelInstallerError.invalidDownloadedModel
      }
    }
    try Self.preparePrivateDirectory(destinationURL)
    guard Self.isValidModelDirectory(destinationURL) else {
      throw MLXLocalModelInstallerError.invalidDownloadedModel
    }
    progress(1)
    return destinationURL
  }

  private static func validatedComponents(for modelID: String) throws -> [String] {
    let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard
      normalized.utf8.count <= 256,
      components.count == 2,
      components.allSatisfy({ component in
        !component.isEmpty
          && component != "."
          && component != ".."
          && component.rangeOfCharacter(from: allowed.inverted) == nil
      })
    else {
      throw MLXLocalModelInstallerError.invalidModelIdentifier
    }
    return components
  }

  private static func validateRoot(_ rootURL: URL) throws {
    let path = rootURL.path
    guard
      rootURL.isFileURL,
      path.hasPrefix("/"),
      path != "/",
      path.utf8.count <= 4_096,
      !path.contains("\0")
    else {
      throw MLXLocalModelInstallerError.invalidDestination
    }
  }

  private static func preparePrivateDirectory(_ directoryURL: URL) throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
  }

  private static func isDescendant(_ candidateURL: URL, of rootURL: URL) -> Bool {
    let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    let candidatePath = candidateURL.standardizedFileURL.resolvingSymlinksInPath().path
    return candidatePath.hasPrefix(rootPath + "/")
  }

  private static func isValidModelDirectory(_ directoryURL: URL) -> Bool {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard
      fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let entries = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: []
      ),
      (3...512).contains(entries.count)
    else {
      return false
    }

    let policy = try? MLXLocalModelResourcePolicy.macWith16GBMemory
    guard let policy else { return false }
    var names = Set<String>()
    var totalBytes: UInt64 = 0
    for entry in entries {
      guard
        let values = try? entry.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize > 0,
        isAllowedArtifactName(entry.lastPathComponent)
      else {
        return false
      }
      let byteCount = UInt64(fileSize)
      if entry.pathExtension == "json" || entry.pathExtension == "jinja" {
        guard byteCount <= policy.maximumControlFileBytes else { return false }
      }
      let (newTotal, overflowed) = totalBytes.addingReportingOverflow(byteCount)
      guard !overflowed, newTotal <= policy.maximumArtifactBytes else { return false }
      totalBytes = newTotal
      names.insert(entry.lastPathComponent)
    }
    return names.contains("config.json")
      && names.contains("tokenizer.json")
      && names.contains(where: { $0.hasSuffix(".safetensors") })
  }

  private static func isAllowedArtifactName(_ name: String) -> Bool {
    !name.isEmpty
      && name.utf8.count <= 255
      && !name.contains("/")
      && !name.contains("\0")
      && (name.hasSuffix(".safetensors") || name.hasSuffix(".json") || name.hasSuffix(".jinja"))
  }
}
