import Darwin
import Foundation

actor AgentConversationStore {
  static let defaultMaximumBytes = 4 * 1_024 * 1_024
  private static let maximumConversations = 64
  private static let maximumTranscriptItems = 512
  private static let maximumTitleBytes = 256
  private static let maximumArchiveBytes = 16 * 1_024 * 1_024

  let fileURL: URL
  private let maximumBytes: Int

  init(fileURL: URL, maximumBytes: Int = AgentConversationStore.defaultMaximumBytes) throws {
    let standardizedURL = fileURL.standardizedFileURL
    guard Self.isValidFileURL(standardizedURL) else {
      throw AgentConversationStoreError.invalidFileURL
    }
    guard (1...Self.maximumArchiveBytes).contains(maximumBytes) else {
      throw AgentConversationStoreError.invalidMaximumBytes
    }

    self.fileURL = standardizedURL
    self.maximumBytes = maximumBytes
  }

  static func live() -> AgentConversationStore? {
    guard
      let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return nil
    }

    let url =
      applicationSupport
      .appendingPathComponent("Hex", isDirectory: true)
      .appendingPathComponent("conversations.json", isDirectory: false)
    return try? AgentConversationStore(fileURL: url)
  }

  func load() throws -> AgentConversationArchive? {
    try Task.checkCancellation()
    try Self.rejectSymlinkAncestors(for: fileURL)
    guard let data = try readArchiveData() else {
      return nil
    }
    guard !data.isEmpty else {
      throw AgentConversationStoreError.malformedArchive
    }

    let archive: AgentConversationArchive
    do {
      archive = try JSONDecoder().decode(AgentConversationArchive.self, from: data)
    } catch {
      throw AgentConversationStoreError.malformedArchive
    }

    guard archive.schemaVersion == AgentConversationArchive.currentSchemaVersion else {
      throw AgentConversationStoreError.unsupportedSchemaVersion(Int(archive.schemaVersion))
    }
    try Self.validate(archive)

    let canonicalData = try Self.encode(archive)
    guard canonicalData == data else {
      throw AgentConversationStoreError.malformedArchive
    }
    return archive
  }

  func save(_ archive: AgentConversationArchive) throws {
    try Task.checkCancellation()
    guard archive.schemaVersion == AgentConversationArchive.currentSchemaVersion else {
      throw AgentConversationStoreError.unsupportedSchemaVersion(Int(archive.schemaVersion))
    }
    try Self.validate(archive)
    let data = try Self.encode(archive)
    guard data.count <= maximumBytes else {
      throw AgentConversationStoreError.archiveTooLarge(
        actual: data.count,
        maximum: maximumBytes
      )
    }

    let directoryURL = fileURL.deletingLastPathComponent()
    try Self.rejectSymlinkAncestors(for: fileURL)
    try Self.ensurePrivateDirectory(at: directoryURL)
    try Self.validateExistingFile(at: fileURL)

    do {
      try data.write(to: fileURL, options: [.atomic])
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: fileURL.path
      )
    } catch {
      throw AgentConversationStoreError.ioFailure
    }
    try Task.checkCancellation()
  }

  private func readArchiveData() throws -> Data? {
    let descriptor = fileURL.path.withCString { path in
      Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      let openError = errno
      if openError == ENOENT {
        return nil
      }
      if openError == ELOOP {
        throw AgentConversationStoreError.unsafeFile
      }
      throw AgentConversationStoreError.ioFailure
    }
    defer {
      _ = Darwin.close(descriptor)
    }

    var initialStatus = stat()
    guard fstat(descriptor, &initialStatus) == 0 else {
      throw AgentConversationStoreError.ioFailure
    }
    try Self.validateRegularFile(initialStatus)
    guard
      initialStatus.st_size >= 0,
      initialStatus.st_size <= off_t(maximumBytes),
      let expectedSize = Int(exactly: initialStatus.st_size)
    else {
      throw AgentConversationStoreError.archiveTooLarge(
        actual: Int.max,
        maximum: maximumBytes
      )
    }

    var data = Data()
    data.reserveCapacity(expectedSize)
    let bufferSize = min(maximumBytes, 64 * 1_024)
    var buffer = [UInt8](repeating: 0, count: max(bufferSize, 1))
    var remaining = expectedSize
    while remaining > 0 {
      let requested = min(remaining, buffer.count)
      let count = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, requested)
      }
      if count > 0 {
        data.append(contentsOf: buffer.prefix(count))
        remaining -= count
      } else if count < 0, errno == EINTR {
        continue
      } else {
        throw AgentConversationStoreError.ioFailure
      }
    }

    var finalStatus = stat()
    guard fstat(descriptor, &finalStatus) == 0 else {
      throw AgentConversationStoreError.ioFailure
    }
    guard
      Self.sameIdentity(initialStatus, finalStatus),
      finalStatus.st_size == initialStatus.st_size,
      data.count == expectedSize
    else {
      throw AgentConversationStoreError.ioFailure
    }
    return data
  }

  private nonisolated static func encode(_ archive: AgentConversationArchive) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      return try encoder.encode(archive)
    } catch {
      throw AgentConversationStoreError.malformedArchive
    }
  }

  private nonisolated static func validate(_ archive: AgentConversationArchive) throws {
    guard archive.conversations.count <= maximumConversations else {
      throw AgentConversationStoreError.invalidArchive(
        "It contains more than \(maximumConversations) conversations."
      )
    }

    var conversationIDs = Set<UUID>()
    for conversation in archive.conversations {
      guard conversationIDs.insert(conversation.id).inserted else {
        throw AgentConversationStoreError.invalidArchive(
          "It contains duplicate conversation identities."
        )
      }
      guard
        !conversation.title.isEmpty,
        conversation.title.utf8.count <= maximumTitleBytes,
        conversation.createdAt.timeIntervalSinceReferenceDate.isFinite,
        conversation.updatedAt.timeIntervalSinceReferenceDate.isFinite,
        conversation.updatedAt >= conversation.createdAt
      else {
        throw AgentConversationStoreError.invalidArchive(
          "A conversation has an invalid title or timestamp."
        )
      }
      guard conversation.transcript.count <= maximumTranscriptItems else {
        throw AgentConversationStoreError.invalidArchive(
          "A conversation contains too many transcript items."
        )
      }
      for item in conversation.transcript {
        guard
          !item.text.isEmpty,
          item.text.utf8.count <= AgentConversation.maximumPersistedTextBytes,
          item.timestamp.timeIntervalSinceReferenceDate.isFinite
        else {
          throw AgentConversationStoreError.invalidArchive(
            "A transcript item is empty, oversized, or has an invalid timestamp."
          )
        }
      }
    }

    if let selectedConversationID = archive.selectedConversationID {
      guard conversationIDs.contains(selectedConversationID) else {
        throw AgentConversationStoreError.invalidArchive(
          "The selected conversation does not exist."
        )
      }
    }
  }

  private nonisolated static func ensurePrivateDirectory(at url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: url.path
      )
    } catch {
      throw AgentConversationStoreError.ioFailure
    }

    var status = stat()
    guard
      lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0
    else {
      throw AgentConversationStoreError.unsafeFile
    }
  }

  private nonisolated static func validateExistingFile(at url: URL) throws {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
      guard errno == ENOENT else {
        throw AgentConversationStoreError.ioFailure
      }
      return
    }
    try validateRegularFile(status)
  }

  private nonisolated static func validateRegularFile(_ status: stat) throws {
    guard
      status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(),
      status.st_nlink == 1,
      status.st_mode & 0o077 == 0
    else {
      throw AgentConversationStoreError.unsafeFile
    }
  }

  private nonisolated static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private nonisolated static func isValidFileURL(_ url: URL) -> Bool {
    let path = url.path
    let parentPath = url.deletingLastPathComponent().path
    guard
      url.isFileURL,
      path.hasPrefix("/"),
      !path.isEmpty,
      parentPath != "/",
      path.utf8.count <= 4_096,
      !path.contains("\0")
    else {
      return false
    }
    let lastPathComponent = url.lastPathComponent
    return !lastPathComponent.isEmpty && lastPathComponent != "." && lastPathComponent != ".."
  }

  private nonisolated static func rejectSymlinkAncestors(for fileURL: URL) throws {
    var currentURL = fileURL.deletingLastPathComponent().standardizedFileURL
    while currentURL.path != "/" {
      var status = stat()
      if lstat(currentURL.path, &status) == 0 {
        if status.st_mode & S_IFMT == S_IFLNK {
          guard Self.isTrustedSystemAlias(currentURL) else {
            throw AgentConversationStoreError.unsafeFile
          }
        }
      } else {
        guard errno == ENOENT else {
          throw AgentConversationStoreError.ioFailure
        }
      }
      currentURL.deleteLastPathComponent()
    }
  }

  private nonisolated static func isTrustedSystemAlias(_ url: URL) -> Bool {
    let expectedDestination: String?
    switch url.path {
    case "/tmp":
      expectedDestination = "private/tmp"
    case "/var":
      expectedDestination = "private/var"
    default:
      expectedDestination = nil
    }
    guard let expectedDestination else {
      return false
    }
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    else {
      return false
    }
    return destination == expectedDestination
  }
}
