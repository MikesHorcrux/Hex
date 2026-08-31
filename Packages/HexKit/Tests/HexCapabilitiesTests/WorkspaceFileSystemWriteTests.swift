import Darwin
import Foundation
import Testing

@testable import HexCapabilities

@Suite("Workspace file-system writes")
struct WorkspaceFileSystemWriteTests {
  @Test
  func rejectsHighExpansionBeforeConstructingTheReplacement() throws {
    let source = String(repeating: "x", count: 10_000)
    let replacement = String(repeating: "y", count: 1 * 1_024 * 1_024)

    #expect(throws: WorkspaceFileSystemError.fileTooLarge) {
      _ = try BoundedTextReplacement.build(
        source: source,
        replacing: "x",
        with: replacement,
        expectedOccurrences: 10_000,
        maximumBytes: 1 * 1_024 * 1_024
      )
    }
  }

  @Test
  func accountsForActualUTF8BytesInCanonicallyEquivalentMatches() throws {
    let decomposedSource = "e\u{301}"
    let composedPattern = "é"
    #expect(decomposedSource.utf8.count == 3)
    #expect(composedPattern.utf8.count == 2)

    let result = try BoundedTextReplacement.build(
      source: decomposedSource,
      replacing: composedPattern,
      with: "x",
      expectedOccurrences: 1,
      maximumBytes: 4
    )

    #expect(result == "x")
    #expect(result.utf8.count == 1)
  }

  @Test
  func createsThenRevisionGuardsAtomicReplacement() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileSystem = try WorkspaceFileSystem(root: root)

    let created = try await fileSystem.writeTextFile(
      "one",
      at: "Sources/New.swift",
      expectedRevision: nil,
      relativeTo: nil
    )
    #expect(created.content == "one")

    await #expect(throws: WorkspaceFileSystemError.destinationExists) {
      _ = try await fileSystem.writeTextFile(
        "unexpected",
        at: "Sources/New.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }
    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "unexpected",
        at: "Sources/New.swift",
        expectedRevision: String(repeating: "0", count: 64),
        relativeTo: nil
      )
    }

    let replaced = try await fileSystem.writeTextFile(
      "two",
      at: "Sources/New.swift",
      expectedRevision: created.revision,
      relativeTo: nil
    )
    #expect(replaced.content == "two")
    #expect(replaced.revision != created.revision)
    #expect(
      try String(contentsOf: root.appending(path: "Sources/New.swift"), encoding: .utf8) == "two")
  }

  @Test
  func exactReplacementIsTransactionalAndCountBounded() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileSystem = try WorkspaceFileSystem(root: root)
    let created = try await fileSystem.writeTextFile(
      "red blue red",
      at: "Sources/Colors.swift",
      expectedRevision: nil,
      relativeTo: nil
    )

    await #expect(throws: WorkspaceFileSystemError.replacementCountMismatch) {
      _ = try await fileSystem.replaceText(
        "red",
        with: "green",
        in: "Sources/Colors.swift",
        expectedRevision: created.revision,
        expectedOccurrences: 1,
        relativeTo: nil
      )
    }
    #expect(
      try await fileSystem.readTextFile(at: "Sources/Colors.swift", relativeTo: nil).content
        == "red blue red"
    )

    let replaced = try await fileSystem.replaceText(
      "red",
      with: "green",
      in: "Sources/Colors.swift",
      expectedRevision: created.revision,
      expectedOccurrences: 2,
      relativeTo: nil
    )
    #expect(replaced.content == "green blue green")
  }

  @Test
  func rejectsSymlinkDestinationsWithoutMutatingTheirTargets() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target.swift")
    try Data("original".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "alias.swift"),
      withDestinationURL: target
    )
    let fileSystem = try WorkspaceFileSystem(root: root)

    await #expect(throws: WorkspaceFileSystemError.symbolicLinkRejected) {
      _ = try await fileSystem.writeTextFile(
        "changed",
        at: "alias.swift",
        expectedRevision: String(repeating: "0", count: 64),
        relativeTo: nil
      )
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
  }

  @Test
  func cancellationBeforeMutationCreatesNothing() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileSystem = try WorkspaceFileSystem(root: root)
    let task = Task {
      withUnsafeCurrentTask { currentTask in
        currentTask?.cancel()
      }
      return try await fileSystem.writeTextFile(
        "never written",
        at: "Sources/Cancelled.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(
      !FileManager.default.fileExists(atPath: root.appending(path: "Sources/Cancelled.swift").path))
  }

  @Test
  func cancellationAfterCreationLinkRemovesPublishedFileAndTemporaryFileBeforeThrowing()
    async throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
    let destination = sources.appending(path: "CancelledCreation.swift")
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      creationPostLinkHook: {
        withUnsafeCurrentTask { currentTask in
          currentTask?.cancel()
        }
      }
    )

    let task = Task {
      try await fileSystem.writeTextFile(
        "never committed",
        at: "Sources/CancelledCreation.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    let remainingEntries = try FileManager.default.contentsOfDirectory(atPath: sources.path)
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(remainingEntries.isEmpty)
    #expect(!remainingEntries.contains { $0.hasPrefix(".hex-write-") })
  }

  @Test
  func cancellationAfterReplacementSwapRestoresOriginalAndRemovesTemporaryFileBeforeThrowing()
    async throws
  {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
    let destination = sources.appending(path: "CancelledReplacement.swift")
    try Data("original".utf8).write(to: destination)
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      replacementPostSwapHook: {
        withUnsafeCurrentTask { currentTask in
          currentTask?.cancel()
        }
      }
    )
    let initial = try await fileSystem.readTextFile(
      at: "Sources/CancelledReplacement.swift",
      relativeTo: nil
    )

    let task = Task {
      try await fileSystem.writeTextFile(
        "never committed",
        at: "Sources/CancelledReplacement.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    let remainingEntries = try FileManager.default.contentsOfDirectory(atPath: sources.path)
    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    #expect(remainingEntries == [destination.lastPathComponent])
    #expect(!remainingEntries.contains { $0.hasPrefix(".hex-write-") })
  }

  @Test
  func concurrentCreatesPublishExactlyOneFile() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileSystem = try WorkspaceFileSystem(root: root)

    let outcomes = await withTaskGroup(of: String.self) { group in
      for content in ["first", "second"] {
        group.addTask {
          do {
            _ = try await fileSystem.writeTextFile(
              content,
              at: "Sources/Race.swift",
              expectedRevision: nil,
              relativeTo: nil
            )
            return "success"
          } catch WorkspaceFileSystemError.destinationExists {
            return "destination_exists"
          } catch {
            return "unexpected"
          }
        }
      }
      var values: [String] = []
      for await value in group {
        values.append(value)
      }
      return values.sorted()
    }

    #expect(outcomes == ["destination_exists", "success"])
    let content = try String(
      contentsOf: root.appending(path: "Sources/Race.swift"),
      encoding: .utf8
    )
    #expect(content == "first" || content == "second")
  }

  @Test
  func concurrentReplacementsConsumeOneRevisionExactlyOnce() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileSystem = try WorkspaceFileSystem(root: root)
    let initial = try await fileSystem.writeTextFile(
      "initial",
      at: "Sources/Race.swift",
      expectedRevision: nil,
      relativeTo: nil
    )

    let outcomes = await withTaskGroup(of: String.self) { group in
      for content in ["first replacement", "second replacement"] {
        group.addTask {
          do {
            _ = try await fileSystem.writeTextFile(
              content,
              at: "Sources/Race.swift",
              expectedRevision: initial.revision,
              relativeTo: nil
            )
            return "success"
          } catch WorkspaceFileSystemError.revisionConflict {
            return "revision_conflict"
          } catch {
            return "unexpected"
          }
        }
      }
      var values: [String] = []
      for await value in group {
        values.append(value)
      }
      return values.sorted()
    }

    #expect(outcomes == ["revision_conflict", "success"])
    let content = try String(
      contentsOf: root.appending(path: "Sources/Race.swift"),
      encoding: .utf8
    )
    #expect(content == "first replacement" || content == "second replacement")
  }

  @Test
  func externalReplacementAtPublicationBoundaryIsPreserved() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Race.swift")
    let externalContent = "external replacement"
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: {
        try Data(externalContent.utf8).write(to: destination, options: .atomic)
      }
    )
    let initial = try await fileSystem.writeTextFile(
      "initial",
      at: "Sources/Race.swift",
      expectedRevision: nil,
      relativeTo: nil
    )

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Race.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == externalContent)
  }

  @Test
  func externalInPlaceMutationAtPublicationBoundaryIsPreserved() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Race.swift")
    let externalContent = "external in-place mutation"
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: {
        let handle = try FileHandle(forWritingTo: destination)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(externalContent.utf8))
        try handle.close()
      }
    )
    let initial = try await fileSystem.writeTextFile(
      "initial",
      at: "Sources/Race.swift",
      expectedRevision: nil,
      relativeTo: nil
    )

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Race.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == externalContent)
  }

  @Test
  func movedParentReplacementIsRolledBackWithoutContentLoss() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appending(path: "Sources", directoryHint: .isDirectory)
    let movedParent = FileManager.default.temporaryDirectory.appending(
      path: "hex-moved-sources-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: movedParent) }
    let destination = parent.appending(path: "Move.swift")
    try Data("original".utf8).write(to: destination)
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: {
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      }
    )
    let initial = try await fileSystem.readTextFile(at: "Sources/Move.swift", relativeTo: nil)

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Move.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(
      try String(contentsOf: movedParent.appending(path: "Move.swift"), encoding: .utf8)
        == "original")
    #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "Move.swift").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: movedParent.path) == ["Move.swift"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
  }

  @Test
  func movedParentCreationIsRemovedBeforeFailure() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appending(path: "Sources", directoryHint: .isDirectory)
    let movedParent = FileManager.default.temporaryDirectory.appending(
      path: "hex-moved-create-sources-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: movedParent) }
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      creationPublicationHook: {
        try FileManager.default.moveItem(at: parent, to: movedParent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
      }
    )

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent creation",
        at: "Sources/New.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }

    #expect(!FileManager.default.fileExists(atPath: movedParent.appending(path: "New.swift").path))
    #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "New.swift").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: movedParent.path).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
  }

  @Test
  func concurrentPermissionChangeIsPreservedAndFailsClosed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Mode.swift")
    try Data("original".utf8).write(to: destination)
    #expect(chmod(destination.path, mode_t(0o644)) == 0)
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      replacementPostValidationHook: {
        guard chmod(destination.path, mode_t(0o600)) == 0 else {
          throw WorkspaceFileSystemError.ioFailure
        }
      }
    )
    let initial = try await fileSystem.readTextFile(at: "Sources/Mode.swift", relativeTo: nil)

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Mode.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
  }

  @Test
  func postValidationIdentityReplacementIsPreservedAndFailsClosed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Identity.swift")
    try Data("original".utf8).write(to: destination)
    let externalContent = "external replacement after validation"
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      replacementPostValidationHook: {
        try Data(externalContent.utf8).write(to: destination, options: .atomic)
      }
    )
    let initial = try await fileSystem.readTextFile(at: "Sources/Identity.swift", relativeTo: nil)

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Identity.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == externalContent)
  }

  @Test
  func postValidationExtendedAttributeMutationIsPreservedAndFailsClosed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Metadata.swift")
    try Data("original".utf8).write(to: destination)
    let attributeName = "com.lunarmoth.hex.concurrent-metadata"
    let attributeValue = Data("external metadata".utf8)
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      replacementPostValidationHook: {
        try Self.setExtendedAttribute(
          named: attributeName,
          value: attributeValue,
          at: destination
        )
      }
    )
    let initial = try await fileSystem.readTextFile(at: "Sources/Metadata.swift", relativeTo: nil)

    await #expect(throws: WorkspaceFileSystemError.revisionConflict) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Metadata.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    #expect(try Self.extendedAttribute(named: attributeName, at: destination) == attributeValue)
  }

  @Test
  func successfulReplacementPreservesExistingMetadata() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Metadata.swift")
    try Data("original".utf8).write(to: destination)
    let attributeName = "com.lunarmoth.hex.existing-metadata"
    let attributeValue = Data("preserve me".utf8)
    try Self.setExtendedAttribute(named: attributeName, value: attributeValue, at: destination)
    #expect(chmod(destination.path, mode_t(0o640)) == 0)
    let expectedFlags = UInt32(UF_NODUMP | UF_HIDDEN)
    #expect(chflags(destination.path, expectedFlags) == 0)
    let fileSystem = try WorkspaceFileSystem(root: root)
    let initial = try await fileSystem.readTextFile(at: "Sources/Metadata.swift", relativeTo: nil)

    _ = try await fileSystem.writeTextFile(
      "agent replacement",
      at: "Sources/Metadata.swift",
      expectedRevision: initial.revision,
      relativeTo: nil
    )

    #expect(try Self.extendedAttribute(named: attributeName, at: destination) == attributeValue)
    var status = stat()
    #expect(lstat(destination.path, &status) == 0)
    #expect(status.st_mode & mode_t(0o7777) == mode_t(0o640))
    #expect(status.st_flags == expectedFlags)
  }

  @Test
  func rejectsDeletionBlockingFlagsBeforeCreatingTemporaryFiles() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Immutable.swift")
    try Data("original".utf8).write(to: destination)
    #expect(chflags(destination.path, UInt32(UF_IMMUTABLE)) == 0)
    defer { _ = chflags(destination.path, 0) }
    let fileSystem = try WorkspaceFileSystem(root: root)
    let initial = try await fileSystem.readTextFile(at: "Sources/Immutable.swift", relativeTo: nil)

    await #expect(throws: WorkspaceFileSystemError.ioFailure) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/Immutable.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: destination.deletingLastPathComponent().path
      ) == ["Immutable.swift"]
    )
  }

  @Test
  func rejectsAccessControlListsBeforeCreatingTemporaryFiles() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/ACL.swift")
    try Data("original".utf8).write(to: destination)
    try Self.setDenyDeleteAccessControlList(at: destination)
    defer { try? Self.removeAccessControlList(at: destination) }
    let fileSystem = try WorkspaceFileSystem(root: root)
    let initial = try await fileSystem.readTextFile(at: "Sources/ACL.swift", relativeTo: nil)

    await #expect(throws: WorkspaceFileSystemError.ioFailure) {
      _ = try await fileSystem.writeTextFile(
        "agent replacement",
        at: "Sources/ACL.swift",
        expectedRevision: initial.revision,
        relativeTo: nil
      )
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: destination.deletingLastPathComponent().path
      ) == ["ACL.swift"]
    )
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-write-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    return root
  }

  private static func setExtendedAttribute(
    named name: String,
    value: Data,
    at url: URL
  ) throws {
    let result = try value.withUnsafeBytes { bytes in
      try url.path.withCString { path in
        try name.withCString { namePointer in
          let result = setxattr(
            path,
            namePointer,
            bytes.baseAddress,
            bytes.count,
            0,
            0
          )
          guard result == 0 else {
            throw WorkspaceFileSystemError.ioFailure
          }
          return result
        }
      }
    }
    #expect(result == 0)
  }

  private static func extendedAttribute(named name: String, at url: URL) throws -> Data {
    let byteCount = url.path.withCString { path in
      name.withCString { namePointer in
        getxattr(path, namePointer, nil, 0, 0, 0)
      }
    }
    guard byteCount >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    var value = Data(count: byteCount)
    let readCount = value.withUnsafeMutableBytes { bytes in
      url.path.withCString { path in
        name.withCString { namePointer in
          getxattr(path, namePointer, bytes.baseAddress, bytes.count, 0, 0)
        }
      }
    }
    guard readCount == byteCount else {
      throw WorkspaceFileSystemError.ioFailure
    }
    return value
  }

  private static func setDenyDeleteAccessControlList(at url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { Darwin.close(descriptor) }
    let text = """
      !#acl 1
      group:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete

      """
    let result = text.withCString { textPointer -> Int32 in
      guard let acl = acl_from_text(textPointer) else {
        return -1
      }
      defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
      return acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED)
    }
    guard result == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
  }

  private static func removeAccessControlList(at url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { Darwin.close(descriptor) }
    guard let acl = acl_init(1) else {
      throw WorkspaceFileSystemError.ioFailure
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_fd_np(descriptor, acl, ACL_TYPE_EXTENDED) == 0 else {
      throw WorkspaceFileSystemError.ioFailure
    }
  }
}
