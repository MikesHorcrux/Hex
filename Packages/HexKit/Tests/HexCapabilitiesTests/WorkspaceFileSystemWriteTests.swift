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
}
