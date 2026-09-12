import Darwin
import Foundation
import Synchronization
import Testing

@testable import HexCapabilities

@Suite("Workspace file-system transaction regressions", .serialized)
struct WorkspaceFileSystemTransactionRegressionTests {
  @Test
  func namespaceConstructionFailureCannotCreateUnboundedReplacementDirectories() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-emfile-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    var createdPaths: [String] = []
    defer {
      try? FileManager.default.removeItem(at: admissionDirectory)
    }

    let expectedUsage = WorkspaceWriteTransactionNamespaceUsage(
      claimedSlotCount: 0,
      unavailableSlotCount: 64,
      availableSlotCount: 0,
      maximumSlotCount: 64
    )
    for _ in 0..<65 {
      #expect(throws: WorkspaceWriteTransactionNamespaceError.exhausted(expectedUsage)) {
        _ = try WorkspaceWriteTransactionNamespace(
          appropriateFor: root,
          targetDescriptor: descriptor,
          admissionDirectoryURL: admissionDirectory,
          openSlot: { _, name in
            createdPaths.append(admissionDirectory.appending(path: name).path)
            errno = EMFILE
            return -1
          }
        )
      }
    }

    #expect(Set(createdPaths).count == 64)
    #expect(createdPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: admissionDirectory.path).count == 64
    )
  }

  @Test
  func namespaceInspectionFailureCannotCreateMoreThanTheFixedSlotSet() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(descriptor >= 0)
    defer { Darwin.close(descriptor) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-fstat-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: admissionDirectory) }
    let expectedUsage = WorkspaceWriteTransactionNamespaceUsage(
      claimedSlotCount: 0,
      unavailableSlotCount: 64,
      availableSlotCount: 0,
      maximumSlotCount: 64
    )

    for _ in 0..<65 {
      #expect(throws: WorkspaceWriteTransactionNamespaceError.exhausted(expectedUsage)) {
        _ = try WorkspaceWriteTransactionNamespace(
          appropriateFor: root,
          targetDescriptor: descriptor,
          admissionDirectoryURL: admissionDirectory,
          inspectSlot: { _, _ in
            errno = EIO
            return -1
          }
        )
      }
    }

    let entries = try FileManager.default.contentsOfDirectory(atPath: admissionDirectory.path)
    #expect(entries.count == 64)
    #expect(Set(entries).count == 64)
  }

  @Test
  func liveSlotsAreSkippedAndCleanReleasedSlotsAreReused() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-live-slot-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: admissionDirectory) }
    var first: WorkspaceWriteTransactionNamespace? = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 2
    )
    var second: WorkspaceWriteTransactionNamespace? = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 2
    )

    #expect(first?.directoryURL.lastPathComponent == "runtime-slot-00")
    #expect(second?.directoryURL.lastPathComponent == "runtime-slot-01")
    #expect(first?.usage.claimedSlotCount == 1)
    #expect(first?.usage.unavailableSlotCount == 0)
    #expect(first?.usage.availableSlotCount == 1)
    #expect(second?.usage.claimedSlotCount == 1)
    #expect(second?.usage.unavailableSlotCount == 1)
    #expect(second?.usage.availableSlotCount == 0)
    var admissionStatus = stat()
    var slotStatus = stat()
    let firstSlotPath = try #require(first?.directoryURL.path)
    #expect(lstat(admissionDirectory.path, &admissionStatus) == 0)
    #expect(lstat(firstSlotPath, &slotStatus) == 0)
    #expect(admissionStatus.st_uid == geteuid())
    #expect(slotStatus.st_uid == geteuid())
    #expect(admissionStatus.st_mode & mode_t(0o7777) == mode_t(0o700))
    #expect(slotStatus.st_mode & mode_t(0o7777) == mode_t(0o700))
    let exhaustedUsage = WorkspaceWriteTransactionNamespaceUsage(
      claimedSlotCount: 0,
      unavailableSlotCount: 2,
      availableSlotCount: 0,
      maximumSlotCount: 2
    )
    #expect(throws: WorkspaceWriteTransactionNamespaceError.exhausted(exhaustedUsage)) {
      _ = try makeNamespace(
        root: root,
        admissionDirectory: admissionDirectory,
        maximumSlotCount: 2
      )
    }

    first = nil
    let reusedFirst = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 2
    )
    #expect(reusedFirst.directoryURL.lastPathComponent == "runtime-slot-00")
    second = nil
    withExtendedLifetime(reusedFirst) {}
  }

  @Test
  func crossProcessClaimsAreUniqueAndCrashResidueStaysCapacityBounded() throws {
    guard ProcessInfo.processInfo.environment["HEX_NAMESPACE_PROBE_CHILD"] == nil else {
      return
    }
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-process-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let readyFile = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-process-ready-\(UUID().uuidString)"
    )
    defer {
      try? FileManager.default.removeItem(at: admissionDirectory)
      try? FileManager.default.removeItem(at: readyFile)
    }
    let process = try startNamespaceProbeProcess(
      root: root,
      admissionDirectory: admissionDirectory,
      readyFile: readyFile,
      residueCount: 63,
      maximumSlotCount: 2
    )
    defer {
      if process.isRunning {
        process.terminate()
        waitForProcessExit(process)
      }
    }
    let childClaim = try waitForChildClaim(at: readyFile, process: process)
    #expect(childClaim.slotName == "runtime-slot-00")

    var parentNamespace: WorkspaceWriteTransactionNamespace? = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 2
    )
    #expect(parentNamespace?.directoryURL.lastPathComponent == "runtime-slot-01")
    let exhaustedUsage = WorkspaceWriteTransactionNamespaceUsage(
      claimedSlotCount: 0,
      unavailableSlotCount: 2,
      availableSlotCount: 0,
      maximumSlotCount: 2
    )
    #expect(throws: WorkspaceWriteTransactionNamespaceError.exhausted(exhaustedUsage)) {
      _ = try makeNamespace(
        root: root,
        admissionDirectory: admissionDirectory,
        maximumSlotCount: 2
      )
    }

    #expect(kill(childClaim.processIdentifier, SIGKILL) == 0)
    waitForProcessExit(process)
    parentNamespace = nil
    let afterCrash = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 2
    )
    #expect(afterCrash.directoryURL.lastPathComponent == "runtime-slot-01")
    #expect(afterCrash.usage.unavailableSlotCount == 1)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: admissionDirectory.appending(path: "runtime-slot-00").path
      ).count == 63
    )
    withExtendedLifetime(afterCrash) {}
  }

  @Test
  func crashReleasedSlotWithBoundedResidueIsReusedWithoutDeletingResidue() async throws {
    guard ProcessInfo.processInfo.environment["HEX_NAMESPACE_PROBE_CHILD"] == nil else {
      return
    }
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-reusable-crash-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let readyFile = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-reusable-crash-ready-\(UUID().uuidString)"
    )
    defer {
      try? FileManager.default.removeItem(at: admissionDirectory)
      try? FileManager.default.removeItem(at: readyFile)
    }
    let process = try startNamespaceProbeProcess(
      root: root,
      admissionDirectory: admissionDirectory,
      readyFile: readyFile,
      residueCount: 1,
      maximumSlotCount: 1
    )
    defer {
      if process.isRunning {
        process.terminate()
        waitForProcessExit(process)
      }
    }
    let childClaim = try waitForChildClaim(at: readyFile, process: process)
    #expect(childClaim.slotName == "runtime-slot-00")
    #expect(kill(childClaim.processIdentifier, SIGKILL) == 0)
    waitForProcessExit(process)

    let namespace = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 1
    )
    #expect(namespace.directoryURL.lastPathComponent == "runtime-slot-00")
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespace.directoryURL.path)
        == ["crash-residue-0"]
    )
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      writeTransactionNamespace: namespace
    )
    _ = try await fileSystem.writeTextFile(
      "committed after crash",
      at: "Sources/AfterCrash.swift",
      expectedRevision: nil,
      relativeTo: nil
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespace.directoryURL.path)
        == ["crash-residue-0"]
    )
  }

  @Test
  func slotReplacementBetweenOpenAndValidationIsSkippedAndPreserved() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-slot-replacement-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let movedSlot = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-moved-slot-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer {
      try? FileManager.default.removeItem(at: admissionDirectory)
      try? FileManager.default.removeItem(at: movedSlot)
    }
    try FileManager.default.createDirectory(
      at: admissionDirectory.appending(path: "runtime-slot-00"),
      withIntermediateDirectories: true
    )
    #expect(chmod(admissionDirectory.path, mode_t(0o700)) == 0)
    #expect(
      chmod(
        admissionDirectory.appending(path: "runtime-slot-00").path,
        mode_t(0o700)
      ) == 0
    )
    let descriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    defer { Darwin.close(descriptor) }
    var replacedSlot = false
    let namespace = try WorkspaceWriteTransactionNamespace(
      appropriateFor: root,
      targetDescriptor: descriptor,
      admissionDirectoryURL: admissionDirectory,
      maximumSlotCount: 2,
      openSlot: { admissionDescriptor, name in
        let opened = Darwin.openat(
          admissionDescriptor,
          name,
          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard name == "runtime-slot-00", !replacedSlot, opened >= 0 else {
          return opened
        }
        replacedSlot = true
        let publicSlot = admissionDirectory.appending(path: name)
        do {
          try FileManager.default.moveItem(at: publicSlot, to: movedSlot)
          try FileManager.default.createDirectory(
            at: publicSlot,
            withIntermediateDirectories: false
          )
          guard chmod(publicSlot.path, mode_t(0o700)) == 0 else {
            return opened
          }
          try Data("unrelated replacement".utf8).write(
            to: publicSlot.appending(path: "must-survive")
          )
        } catch {
          return opened
        }
        return opened
      }
    )

    #expect(replacedSlot)
    #expect(namespace.directoryURL.lastPathComponent == "runtime-slot-01")
    #expect(
      try String(
        contentsOf:
          admissionDirectory
          .appending(path: "runtime-slot-00")
          .appending(path: "must-survive"),
        encoding: .utf8
      ) == "unrelated replacement"
    )
    withExtendedLifetime(namespace) {}
  }

  @Test
  func namespaceProbeChildProcess() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["HEX_NAMESPACE_PROBE_CHILD"] == "1" else {
      return
    }
    let root = URL(filePath: try #require(environment["HEX_NAMESPACE_PROBE_ROOT"]))
    let admissionDirectory = URL(
      filePath: try #require(environment["HEX_NAMESPACE_PROBE_ADMISSION"])
    )
    let readyFile = URL(filePath: try #require(environment["HEX_NAMESPACE_PROBE_READY"]))
    let residueValue = try #require(environment["HEX_NAMESPACE_PROBE_RESIDUE"])
    let maximumSlotValue = try #require(environment["HEX_NAMESPACE_PROBE_MAXIMUM_SLOTS"])
    let residueCount = try #require(Int(residueValue))
    let maximumSlotCount = try #require(Int(maximumSlotValue))
    let namespace = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: maximumSlotCount
    )
    for index in 0..<residueCount {
      let name = "crash-residue-\(index)"
      let descriptor = openat(
        namespace.directoryDescriptor,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
      )
      #expect(descriptor >= 0)
      guard descriptor >= 0 else {
        continue
      }
      Darwin.close(descriptor)
    }
    #expect(fsync(namespace.directoryDescriptor) == 0)
    try Data("\(getpid())\n\(namespace.directoryURL.lastPathComponent)".utf8)
      .write(to: readyFile, options: .atomic)
    withExtendedLifetime(namespace) {
      while true {
        usleep(100_000)
      }
    }
  }

  @Test
  func repeatedWritesDoNotGrowTheAdmissionOrRuntimeSlot() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-write-growth-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: admissionDirectory) }
    let namespace = try makeNamespace(
      root: root,
      admissionDirectory: admissionDirectory,
      maximumSlotCount: 4
    )
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      writeTransactionNamespace: namespace
    )

    for index in 0..<100 {
      _ = try await fileSystem.writeTextFile(
        "content \(index)",
        at: "Sources/File-\(index).swift",
        expectedRevision: nil,
        relativeTo: nil
      )
    }

    #expect(
      try FileManager.default.contentsOfDirectory(atPath: admissionDirectory.path)
        == [namespace.directoryURL.lastPathComponent]
    )
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespace.directoryURL.path).isEmpty
    )
  }

  @Test
  func admissionTeardownNeverDeletesAReplacementAtItsPublicName() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-admission-replacement-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let movedAdmission = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-moved-admission-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer {
      try? FileManager.default.removeItem(at: admissionDirectory)
      try? FileManager.default.removeItem(at: movedAdmission)
    }
    weak var namespaceProbe: WorkspaceWriteTransactionNamespace?

    try { () throws -> Void in
      let namespace = try makeNamespace(
        root: root,
        admissionDirectory: admissionDirectory,
        maximumSlotCount: 2
      )
      namespaceProbe = namespace
      try FileManager.default.moveItem(at: admissionDirectory, to: movedAdmission)
      try FileManager.default.createDirectory(
        at: admissionDirectory,
        withIntermediateDirectories: false
      )
      try Data("unrelated replacement".utf8).write(
        to: admissionDirectory.appending(path: "must-survive")
      )
      withExtendedLifetime(namespace) {}
    }()

    #expect(namespaceProbe == nil)
    #expect(
      try String(
        contentsOf: admissionDirectory.appending(path: "must-survive"),
        encoding: .utf8
      ) == "unrelated replacement"
    )
  }

  @Test
  func rejectsTargetsOnADeviceDifferentFromTheTemporaryAdmissionRoot() throws {
    var temporaryStatus = stat()
    var deviceStatus = stat()
    #expect(lstat(FileManager.default.temporaryDirectory.path, &temporaryStatus) == 0)
    #expect(lstat("/dev", &deviceStatus) == 0)
    guard temporaryStatus.st_dev != deviceStatus.st_dev else {
      return
    }

    #expect(throws: WorkspaceFileSystemError.outcomeUncertain) {
      _ = try WorkspaceWriteTransactionNamespace(appropriateFor: URL(filePath: "/dev"))
    }
  }

  @Test
  func durableReplacementDoesNotDependOnTheTransactionNamespacePath() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let admissionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-isolated-transactions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: admissionDirectory) }
    let isolatedNamespace = try makeNamespace(
      root: root, admissionDirectory: admissionDirectory, maximumSlotCount: 1)
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
      },
      writeTransactionNamespace: isolatedNamespace
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
    let admission = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-shared-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: admission) }
    let namespace = try makeNamespace(
      root: root, admissionDirectory: admission, maximumSlotCount: 1)
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

  private func makeNamespace(
    root: URL,
    admissionDirectory: URL,
    maximumSlotCount: Int
  ) throws -> WorkspaceWriteTransactionNamespace {
    let descriptor = Darwin.open(
      root.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw WorkspaceFileSystemError.invalidRoot
    }
    defer { Darwin.close(descriptor) }
    return try WorkspaceWriteTransactionNamespace(
      appropriateFor: root,
      targetDescriptor: descriptor,
      admissionDirectoryURL: admissionDirectory,
      maximumSlotCount: maximumSlotCount
    )
  }

  private func startNamespaceProbeProcess(
    root: URL,
    admissionDirectory: URL,
    readyFile: URL,
    residueCount: Int,
    maximumSlotCount: Int
  ) throws -> Process {
    let testExecutablePath = try #require(
      CommandLine.arguments.first { $0.contains(".xctest/Contents/MacOS/HexKitPackageTests") }
    )
    let testExecutable = URL(filePath: testExecutablePath)
    let testingHelper = try #require(CommandLine.arguments.first)
    let process = Process()
    process.executableURL = URL(filePath: testingHelper)
    process.arguments = [
      "--test-bundle-path", testExecutable.path, "--filter",
      "WorkspaceFileSystemTransactionRegressionTests.namespaceProbeChildProcess",
      testExecutable.path, "--testing-library", "swift-testing",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
    environment["HEX_NAMESPACE_PROBE_CHILD"] = "1"
    environment["HEX_NAMESPACE_PROBE_ROOT"] = root.path
    environment["HEX_NAMESPACE_PROBE_ADMISSION"] = admissionDirectory.path
    environment["HEX_NAMESPACE_PROBE_READY"] = readyFile.path
    environment["HEX_NAMESPACE_PROBE_RESIDUE"] = String(residueCount)
    environment["HEX_NAMESPACE_PROBE_MAXIMUM_SLOTS"] = String(maximumSlotCount)
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    output.fileHandleForWriting.closeFile()
    return process
  }

  private func waitForChildClaim(
    at readyFile: URL,
    process: Process
  ) throws -> (processIdentifier: pid_t, slotName: String) {
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: readyFile.path) {
      if !process.isRunning || Date() >= deadline {
        if process.isRunning {
          process.terminate()
          waitForProcessExit(process)
        }
        if let output = process.standardOutput as? Pipe {
          let data = output.fileHandleForReading.readDataToEndOfFile()
          let message = String(decoding: data, as: UTF8.self)
          Issue.record("Namespace probe failed before admission: \(message)")
        }
        throw WorkspaceFileSystemError.ioFailure
      }
      usleep(20_000)
    }
    let components = try String(contentsOf: readyFile, encoding: .utf8)
      .split(separator: "\n", omittingEmptySubsequences: false)
    guard
      components.count == 2,
      let processIdentifier = pid_t(components[0])
    else {
      throw WorkspaceFileSystemError.ioFailure
    }
    return (processIdentifier, String(components[1]))
  }

  private func waitForProcessExit(_ process: Process) {
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning, Date() < deadline {
      usleep(20_000)
    }
    if process.isRunning {
      _ = kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
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
