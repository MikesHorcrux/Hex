import Darwin
import Foundation
import HexCore

public struct MLXLocalModelConfiguration: Equatable, Sendable {
  public let modelID: ModelID
  public let displayName: String
  public let directory: URL
  public let contextWindow: Int?
  public let maximumOutputTokens: Int
  public let supportsToolCalling: Bool
  public let supportsParallelToolCalling: Bool
  private let directoryDevice: UInt64
  private let directoryInode: UInt64

  public init(
    modelID: ModelID,
    displayName: String,
    directory: URL,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int,
    supportsToolCalling: Bool = true,
    supportsParallelToolCalling: Bool = false
  ) throws {
    guard
      Self.isValidIdentifier(modelID.rawValue),
      Self.isValidDisplayName(displayName),
      directory.isFileURL,
      directory.path.hasPrefix("/"),
      !directory.path.contains("\0"),
      (1...1_000_000).contains(maximumOutputTokens),
      contextWindow.map({ (1...10_000_000).contains($0) }) ?? true,
      contextWindow.map({ maximumOutputTokens <= $0 }) ?? true,
      !supportsParallelToolCalling || supportsToolCalling
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    var status = stat()
    guard
      lstat(canonicalDirectory.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    self.modelID = modelID
    self.displayName = displayName
    self.directory = canonicalDirectory
    self.contextWindow = contextWindow
    self.maximumOutputTokens = maximumOutputTokens
    self.supportsToolCalling = supportsToolCalling
    self.supportsParallelToolCalling = supportsParallelToolCalling
    directoryDevice = UInt64(status.st_dev)
    directoryInode = UInt64(status.st_ino)
  }

  public var capabilities: Set<InferenceCapability> {
    var values: Set<InferenceCapability> = [.textInput, .streaming]
    if supportsToolCalling {
      values.insert(.toolCalling)
    }
    if supportsParallelToolCalling {
      values.insert(.parallelToolCalling)
    }
    return values
  }

  public func hasOriginalDirectoryIdentity() -> Bool {
    var status = stat()
    return lstat(directory.path, &status) == 0
      && status.st_mode & S_IFMT == S_IFDIR
      && UInt64(status.st_dev) == directoryDevice
      && UInt64(status.st_ino) == directoryInode
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
  }

  private static func isValidDisplayName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
  }
}
