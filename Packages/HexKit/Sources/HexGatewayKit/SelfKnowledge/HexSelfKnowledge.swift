import Foundation
import HexCore

/// Allowlisted, non-secret locations supplied by the process that actually owns the runtime.
/// A location is not a claim that its file exists, is readable, or grants filesystem authority.
public struct HexSelfKnowledge: Sendable {
  public let settingsFileURL: URL?
  public let inferenceSettingsFileURL: URL?
  public let journalFileURL: URL?
  public let heartbeatFileURL: URL?
  public let personalityFileURL: URL?
  public let memoryFileURL: URL?
  public let managedToolsRootURL: URL?
  public let runningExecutableURL: URL?
  public let runningBundleURL: URL?
  public let sourceRootHintURL: URL?

  public init(
    settingsFileURL: URL? = nil,
    inferenceSettingsFileURL: URL? = nil,
    journalFileURL: URL? = nil,
    heartbeatFileURL: URL? = nil,
    personalityFileURL: URL? = nil,
    memoryFileURL: URL? = nil,
    managedToolsRootURL: URL? = nil,
    runningExecutableURL: URL? = Bundle.main.executableURL,
    runningBundleURL: URL? = Bundle.main.bundleURL,
    sourceRootHintURL: URL? = Self.buildSourceRootHintURL
  ) {
    self.settingsFileURL = settingsFileURL
    self.inferenceSettingsFileURL = inferenceSettingsFileURL
    self.journalFileURL = journalFileURL
    self.heartbeatFileURL = heartbeatFileURL
    self.personalityFileURL = personalityFileURL
    self.memoryFileURL = memoryFileURL
    self.managedToolsRootURL = managedToolsRootURL
    self.runningExecutableURL = runningExecutableURL
    self.runningBundleURL = runningBundleURL
    self.sourceRootHintURL = sourceRootHintURL
  }

  /// A build-time hint only. The snapshot verifies the expected layout at this location each run;
  /// release binaries on another Mac normally cannot resolve it. Never substitute the workspace.
  public static var buildSourceRootHintURL: URL? {
    guard #filePath.hasPrefix("/") else { return nil }
    var candidate = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
      candidate.deleteLastPathComponent()
    }
    return candidate.isFileURL && candidate.path != "/" ? candidate : nil
  }

  public func snapshot(
    provider: ProviderDescriptor,
    modelID: ModelID,
    workingDirectory: URL?,
    options: InferenceOptions
  ) -> JSONValue {
    .object([
      "schema": .string("hex_runtime_self"),
      "schemaVersion": .integer(1),
      "workspace": .object(["effectiveRoot": Self.pathValue(workingDirectory)]),
      "data": .object([
        "residentSettings": Self.pathValue(settingsFileURL),
        "inferenceSettings": Self.pathValue(inferenceSettingsFileURL),
        "eventJournal": Self.pathValue(journalFileURL),
        "heartbeats": Self.pathValue(heartbeatFileURL),
        "personality": Self.pathValue(personalityFileURL),
        "personalMemory": Self.pathValue(memoryFileURL),
        "managedTools": Self.pathValue(managedToolsRootURL),
      ]),
      "process": .object([
        "executable": Self.pathValue(runningExecutableURL),
        "bundle": Self.pathValue(runningBundleURL),
      ]),
      "source": sourceValue,
      "inference": .object([
        "providerID": .string(provider.id.rawValue),
        "providerName": .string(provider.displayName),
        "requestedModelID": .string(modelID.rawValue),
        "requestedReasoningEffort": options.reasoningEffort.map { .string($0.rawValue) } ?? .null,
        "actualModelAndEffort": .string("not reported by this runtime snapshot"),
      ]),
    ])
  }

  private var sourceValue: JSONValue {
    guard let root = Self.resolvedURL(sourceRootHintURL), Self.hasSourceMarkers(at: root) else {
      return .object([
        "root": .null,
        "docs": .null,
        "origin": .string("unavailable; no verified Hex source hint"),
        "runningRevisionMatch": .string("unverified"),
      ])
    }
    return .object([
      "root": Self.pathValue(root),
      "docs": Self.pathValue(root.appendingPathComponent("docs", isDirectory: true)),
      "origin": .string(
        sourceRootHintURL == Self.buildSourceRootHintURL
          ? "build-time source hint; expected Hex source markers verified at run start"
          : "explicit host source hint; expected Hex source markers verified at run start"
      ),
      "runningRevisionMatch": .string(
        "unverified; current checkout may differ from running binary"),
    ])
  }

  private static func hasSourceMarkers(at root: URL) -> Bool {
    let files = [
      "Packages/HexKit/Package.swift",
      "Packages/HexKit/Sources/HexGatewayKit/Composition/HexAgentOperatingContract.swift",
      "Hex.xcodeproj/project.pbxproj",
      "docs/architecture/ownership.md",
    ]
    return files.allSatisfy { path in
      let url = root.appendingPathComponent(path, isDirectory: false)
      guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { return false }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
      return values.isRegularFile == true
    }
  }

  private static func pathValue(_ url: URL?) -> JSONValue {
    guard let resolved = resolvedURL(url) else { return .null }
    return .string(resolved.path)
  }

  private static func resolvedURL(_ url: URL?) -> URL? {
    guard let url, url.isFileURL, url.path.hasPrefix("/"),
      !url.path.contains("\0"), url.path.utf8.count <= 4_096
    else { return nil }
    return url.resolvingSymlinksInPath().standardizedFileURL
  }
}
