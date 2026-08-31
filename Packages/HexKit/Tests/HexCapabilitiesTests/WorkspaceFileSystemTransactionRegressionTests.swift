import Foundation
import Synchronization
import Testing

@testable import HexCapabilities

@Suite("Workspace file-system transaction regressions")
struct WorkspaceFileSystemTransactionRegressionTests {
  @Test
  func durableReplacementDoesNotDependOnTheTransactionNamespacePath() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "Sources/Committed.swift")
    try Data("original".utf8).write(to: destination)
    let movedNamespace = FileManager.default.temporaryDirectory.appending(
      path: "hex-moved-write-namespace-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let observedNamespace = Mutex<URL?>(nil)
    defer {
      try? FileManager.default.removeItem(at: movedNamespace)
      if let namespace = observedNamespace.withLock({ $0 }) {
        try? FileManager.default.removeItem(at: namespace)
      }
    }
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      replacementPublicationHook: nil,
      transactionPreTeardownHook: { namespace in
        let shouldMoveNamespace = observedNamespace.withLock { observedNamespace in
          guard observedNamespace == nil else {
            return false
          }
          observedNamespace = namespace
          return true
        }
        guard shouldMoveNamespace else {
          return
        }
        try FileManager.default.moveItem(at: namespace, to: movedNamespace)
        try FileManager.default.createDirectory(
          at: namespace,
          withIntermediateDirectories: false
        )
      }
    )
    let initial = try await fileSystem.readTextFile(
      at: "Sources/Committed.swift",
      relativeTo: nil
    )

    let committed = try await fileSystem.writeTextFile(
      "committed replacement",
      at: "Sources/Committed.swift",
      expectedRevision: initial.revision,
      relativeTo: nil
    )

    #expect(committed.content == "committed replacement")
    #expect(try String(contentsOf: destination, encoding: .utf8) == committed.content)
    _ = try await fileSystem.writeTextFile(
      "still live",
      at: "Sources/AfterMove.swift",
      expectedRevision: nil,
      relativeTo: nil
    )
    #expect(try FileManager.default.contentsOfDirectory(atPath: movedNamespace.path).isEmpty)
    let replacementNamespace = try #require(observedNamespace.withLock { $0 })
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: replacementNamespace.path).isEmpty
    )
  }

  @Test
  func successfulWritesReuseOneRetainedRuntimeNamespace() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let namespaces = try await { () async throws -> [URL] in
      let observedNamespaces = Mutex<[URL]>([])
      let fileSystem = try WorkspaceFileSystem(
        root: root,
        replacementPublicationHook: nil,
        transactionPreTeardownHook: { namespace in
          observedNamespaces.withLock { $0.append(namespace) }
        }
      )
      let first = try await fileSystem.writeTextFile(
        "first",
        at: "Sources/First.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
      _ = try await fileSystem.writeTextFile(
        "second",
        at: "Sources/Second.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
      _ = try await fileSystem.writeTextFile(
        "first replacement",
        at: "Sources/First.swift",
        expectedRevision: first.revision,
        relativeTo: nil
      )
      return observedNamespaces.withLock { $0 }
    }()
    defer {
      for namespace in Set(namespaces) {
        try? FileManager.default.removeItem(at: namespace)
      }
    }

    #expect(namespaces.count == 3)
    #expect(Set(namespaces).count == 1)
    let namespace = try #require(namespaces.first)
    #expect(FileManager.default.fileExists(atPath: namespace.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: namespace.path).isEmpty)
  }

  @Test
  func namespaceTeardownNeverDeletesAReplacementAtItsPublicName() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let movedNamespace = FileManager.default.temporaryDirectory.appending(
      path: "hex-retained-descriptor-namespace-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let observedNamespace = Mutex<URL?>(nil)
    weak var namespaceProbe: WorkspaceWriteTransactionNamespace?
    defer {
      try? FileManager.default.removeItem(at: movedNamespace)
      if let namespace = observedNamespace.withLock({ $0 }) {
        try? FileManager.default.removeItem(at: namespace)
      }
    }

    try await { () async throws -> Void in
      let namespace = try WorkspaceWriteTransactionNamespace(appropriateFor: root)
      namespaceProbe = namespace
      let fileSystem = try WorkspaceFileSystem(
        root: root,
        replacementPublicationHook: nil,
        transactionPreTeardownHook: { namespaceURL in
          observedNamespace.withLock { $0 = namespaceURL }
          try FileManager.default.moveItem(at: namespaceURL, to: movedNamespace)
          try FileManager.default.createDirectory(
            at: namespaceURL,
            withIntermediateDirectories: false
          )
        },
        writeTransactionNamespace: namespace
      )
      _ = try await fileSystem.writeTextFile(
        "committed",
        at: "Sources/TeardownBoundary.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }()

    #expect(namespaceProbe == nil)
    let replacementNamespace = try #require(observedNamespace.withLock { $0 })
    #expect(FileManager.default.fileExists(atPath: replacementNamespace.path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: replacementNamespace.path).isEmpty
    )
  }

  @Test
  func residueCapacityFailsClosedBeforeCreatingAnotherCandidate() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = try WorkspaceWriteTransactionNamespace(appropriateFor: root)
    defer { try? FileManager.default.removeItem(at: namespace.directoryURL) }
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      writeTransactionNamespace: namespace
    )
    for index in 0..<63 {
      let residue = namespace.directoryURL.appending(path: "residue-\(index)")
      try Data().write(to: residue, options: .withoutOverwriting)
    }
    let entriesBeforeWrite = try FileManager.default.contentsOfDirectory(
      atPath: namespace.directoryURL.path
    )

    await #expect(throws: WorkspaceFileSystemError.capacityExceeded) {
      _ = try await fileSystem.writeTextFile(
        "must not start",
        at: "Sources/Capacity.swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }

    #expect(
      !FileManager.default.fileExists(atPath: root.appending(path: "Sources/Capacity.swift").path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespace.directoryURL.path).sorted()
        == entriesBeforeWrite.sorted()
    )
  }

  @Test
  func oneInjectedNamespaceIsReusableAcrossWorkspaceActors() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let namespace = try WorkspaceWriteTransactionNamespace(appropriateFor: root)
    defer { try? FileManager.default.removeItem(at: namespace.directoryURL) }
    let firstFileSystem = try WorkspaceFileSystem(
      root: root,
      writeTransactionNamespace: namespace
    )
    let secondFileSystem = try WorkspaceFileSystem(
      root: root,
      writeTransactionNamespace: namespace
    )

    async let first = firstFileSystem.writeTextFile(
      "first",
      at: "Sources/FirstActor.swift",
      expectedRevision: nil,
      relativeTo: nil
    )
    async let second = secondFileSystem.writeTextFile(
      "second",
      at: "Sources/SecondActor.swift",
      expectedRevision: nil,
      relativeTo: nil
    )
    let (firstResult, secondResult) = try await (first, second)

    #expect(firstResult.content == "first")
    #expect(secondResult.content == "second")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespace.directoryURL.path).isEmpty
    )
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-transaction-regression-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: root.appending(path: "Sources", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    return root
  }
}
