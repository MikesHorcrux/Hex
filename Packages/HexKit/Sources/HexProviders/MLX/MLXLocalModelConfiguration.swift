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
  public let resourcePolicy: MLXLocalModelResourcePolicy
  private let directoryDevice: UInt64
  private let directoryInode: UInt64
  private let directoryOwner: UInt64
  private let directoryGroup: UInt64
  private let directoryPermissions: UInt64

  public init(
    modelID: ModelID,
    displayName: String,
    directory: URL,
    contextWindow: Int? = nil,
    maximumOutputTokens: Int,
    /// Tool calling is opt-in and should only be enabled after model support is verified.
    supportsToolCalling: Bool = false,
    supportsParallelToolCalling: Bool = false,
    resourcePolicy: MLXLocalModelResourcePolicy? = nil
  ) throws {
    let selectedResourcePolicy = try resourcePolicy ?? Self.defaultResourcePolicy()
    guard
      Self.isValidIdentifier(modelID.rawValue),
      Self.isValidDisplayName(displayName),
      directory.isFileURL,
      directory.path.hasPrefix("/"),
      !directory.path.contains("\0"),
      (1...selectedResourcePolicy.maximumOutputTokens).contains(maximumOutputTokens),
      contextWindow.map({
        (1...selectedResourcePolicy.maximumContextTokens).contains($0)
      }) ?? true,
      contextWindow.map({ maximumOutputTokens <= $0 }) ?? true,
      !supportsParallelToolCalling || supportsToolCalling
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
    var status = stat()
    guard lstat(canonicalDirectory.path, &status) == 0 else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    let permissions = UInt64(status.st_mode & mode_t(0o7777))
    guard
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      permissions & 0o022 == 0
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
    self.resourcePolicy = selectedResourcePolicy
    directoryDevice = UInt64(status.st_dev)
    directoryInode = UInt64(status.st_ino)
    directoryOwner = UInt64(status.st_uid)
    directoryGroup = UInt64(status.st_gid)
    directoryPermissions = permissions
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
    guard lstat(directory.path, &status) == 0 else {
      return false
    }
    return matchesOriginalDirectory(status)
      && UInt64(status.st_dev) == directoryDevice
      && UInt64(status.st_ino) == directoryInode
  }

  public func hasOriginalDirectoryIdentity(fileDescriptor: Int32) -> Bool {
    var status = stat()
    guard fstat(fileDescriptor, &status) == 0 else {
      return false
    }
    return matchesOriginalDirectory(status)
      && UInt64(status.st_dev) == directoryDevice
      && UInt64(status.st_ino) == directoryInode
  }

  private func matchesOriginalDirectory(_ status: stat) -> Bool {
    let permissions = UInt64(status.st_mode & mode_t(0o7777))
    return status.st_mode & S_IFMT == S_IFDIR
      && UInt64(status.st_uid) == directoryOwner
      && directoryOwner == UInt64(geteuid())
      && UInt64(status.st_gid) == directoryGroup
      && permissions & 0o022 == 0
      && permissions == directoryPermissions
  }

  private static func isValidIdentifier(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
  }

  private static func isValidDisplayName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && value.utf8.count <= 512 && !value.contains("\0")
  }

  private static func defaultResourcePolicy() throws -> MLXLocalModelResourcePolicy {
    try MLXLocalModelResourcePolicy.macWith16GBMemory
  }
}
