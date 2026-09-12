import Darwin
import Foundation
import Testing

@testable import HexMCP

@Suite("MCP executable snapshot admission", .serialized)
struct MCPExecutableSnapshotAdmissionTests {
  @Test("A released slot is reclaimed beyond the fixed slot cap")
  func releasedSlotIsReclaimedBeyondCap() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    for index in 0..<5 {
      let directory = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace
      )
      let existingNames = try FileManager.default.contentsOfDirectory(
        atPath: directory.path
      )
      #expect(existingNames.isEmpty)
      try Data("retired-\(index)".utf8).write(
        to: URL(fileURLWithPath: directory.path).appendingPathComponent("executable"),
        options: .withoutOverwriting
      )
      close(directory)
    }
  }

  @Test("Stale slots over caller cleanup budgets do not hide a later safe slot")
  func oversizedStaleSlotsDoNotAbortScan() throws {
    let largerPolicy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 3,
      maximumEntriesPerSlot: 8,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 4_096
    )
    let smallerPolicy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 3,
      maximumEntriesPerSlot: 1,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 2
    )
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    let entryLimitedSlot = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: largerPolicy,
      namespaceBasename: namespace
    )
    let entryLimitedURL = URL(fileURLWithPath: entryLimitedSlot.path, isDirectory: true)
    try Data("one".utf8).write(
      to: entryLimitedURL.appendingPathComponent("one"),
      options: .withoutOverwriting
    )
    try Data("two".utf8).write(
      to: entryLimitedURL.appendingPathComponent("two"),
      options: .withoutOverwriting
    )
    let byteLimitedSlot = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: largerPolicy,
      namespaceBasename: namespace
    )
    let byteLimitedURL = URL(fileURLWithPath: byteLimitedSlot.path, isDirectory: true)
    try Data("three".utf8).write(
      to: byteLimitedURL.appendingPathComponent("three"),
      options: .withoutOverwriting
    )
    close(entryLimitedSlot)
    close(byteLimitedSlot)

    let claimed = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: smallerPolicy,
      namespaceBasename: namespace
    )
    defer { close(claimed) }

    #expect(claimed.basename == "slot-0002")
    #expect(try FileManager.default.contentsOfDirectory(atPath: entryLimitedURL.path).count == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: byteLimitedURL.path).count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: claimed.path).isEmpty)
  }

  @Test("Repeated slot scans use independent directory offsets")
  func repeatedSlotScansDoNotReuseDirectoryOffset() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }
    let directory = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    defer { close(directory) }
    try Data("retired".utf8).write(
      to: URL(fileURLWithPath: directory.path).appendingPathComponent("executable"),
      options: .withoutOverwriting
    )

    #expect(try MCPExecutableSnapshot.directoryEntryNames(directory.descriptor) == ["executable"])
    #expect(try MCPExecutableSnapshot.directoryEntryNames(directory.descriptor) == ["executable"])
  }

  @Test("A live slot lease prevents concurrent reclamation")
  func liveSlotLeasePreventsReclamation() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    let live = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    defer { close(live) }

    let expectedUsage = MCPExecutableSnapshotNamespaceUsage(
      namespacePath: namespaceURL.path,
      retainedSlotCount: 1,
      policy: policy
    )
    #expect(
      throws: MCPExecutableSnapshotAdmissionError.namespaceExhausted(expectedUsage)
    ) {
      _ = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace
      )
    }
  }

  @Test("A spawned MCP process keeps its slot lease if the gateway exits")
  func spawnedProcessInheritsSlotLease() throws {
    let policy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 1,
      maximumEntriesPerSlot: 8,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 1 * 1_024 * 1_024
    )
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }
    let fixtureDirectory = URL(
      fileURLWithPath: "/private/tmp/hex-mcp-lease-fixture.\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    try FileManager.default.createDirectory(
      at: fixtureDirectory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let executableURL = fixtureDirectory.appendingPathComponent("server")
    try compileWaitingFixture(at: executableURL)
    let configuration = try MCPServerConfiguration(
      serverID: "lease-fixture",
      executableURL: executableURL,
      arguments: [],
      workingDirectory: fixtureDirectory,
      environment: ["PATH": "/usr/bin:/bin"],
      executableSnapshotPolicy: policy
    )
    var spawned: MCPSpawnedProcess? = try MCPStdioProcessSpawner.spawn(
      configuration,
      executableSnapshotNamespaceBasename: namespace
    )
    let processID = try #require(spawned?.processID)
    let inputDescriptor = try #require(spawned?.inputDescriptor)
    let outputDescriptor = try #require(spawned?.outputDescriptor)
    let errorDescriptor = try #require(spawned?.errorDescriptor)
    let snapshotExecutablePath = try #require(spawned?.executableSnapshot?.executablePath)
    var processIsRunning = true
    defer {
      Darwin.close(inputDescriptor)
      Darwin.close(outputDescriptor)
      Darwin.close(errorDescriptor)
      if processIsRunning {
        MCPStdioProcessSpawner.terminateImmediately(processID)
      }
    }

    spawned = nil
    var liveSnapshotStatus = stat()
    #expect(lstat(snapshotExecutablePath, &liveSnapshotStatus) == 0)
    #expect(liveSnapshotStatus.st_size > 0)
    #expect(liveSnapshotStatus.st_mode & 0o111 != 0)

    let expectedUsage = MCPExecutableSnapshotNamespaceUsage(
      namespacePath: namespaceURL.path,
      retainedSlotCount: 1,
      policy: policy
    )
    do {
      let unexpected = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace
      )
      close(unexpected)
      Issue.record("The live child process did not retain the slot lease")
    } catch {
      #expect(error as? MCPExecutableSnapshotAdmissionError == .namespaceExhausted(expectedUsage))
    }

    MCPStdioProcessSpawner.terminateImmediately(processID)
    processIsRunning = false
    var retiredSnapshotStatus = stat()
    #expect(lstat(snapshotExecutablePath, &retiredSnapshotStatus) == 0)
    #expect(retiredSnapshotStatus.st_size > 0)
    let reclaimed = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    close(reclaimed)
  }

  @Test("A released slot lease rejects an empty pathname replacement")
  func releasedSlotLeaseRejectsPathReplacement() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    let slotURL = namespaceURL.appendingPathComponent("slot-0000", isDirectory: true)
    let movedSlotURL = namespaceURL.appendingPathComponent(
      "moved-owned-slot",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    let retired = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    close(retired)
    #expect(Darwin.rename(slotURL.path, movedSlotURL.path) == 0)
    #expect(Darwin.mkdir(slotURL.path, 0o700) == 0)

    let expectedUsage = MCPExecutableSnapshotNamespaceUsage(
      namespacePath: namespaceURL.path,
      retainedSlotCount: 1,
      policy: policy
    )
    #expect(
      throws: MCPExecutableSnapshotAdmissionError.namespaceExhausted(expectedUsage)
    ) {
      _ = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace
      )
    }

    var replacementStatus = stat()
    var movedStatus = stat()
    #expect(lstat(slotURL.path, &replacementStatus) == 0)
    #expect(lstat(movedSlotURL.path, &movedStatus) == 0)
    #expect(replacementStatus.st_ino != movedStatus.st_ino)
  }

  @Test("Stale reclamation unlinks a symlink without traversing its target")
  func staleReclamationDoesNotTraverseSymlink() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }
    let outsideURL = URL(
      fileURLWithPath: "/private/tmp/hex-mcp-reclaim-target.\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    try FileManager.default.createDirectory(
      at: outsideURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let sentinelURL = outsideURL.appendingPathComponent("sentinel")
    try Data("preserve".utf8).write(to: sentinelURL, options: .withoutOverwriting)

    let retired = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    let linkPath = URL(fileURLWithPath: retired.path).appendingPathComponent("escape").path
    #expect(Darwin.symlink(outsideURL.path, linkPath) == 0)
    close(retired)

    let reclaimed = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    defer { close(reclaimed) }

    #expect(try Data(contentsOf: sentinelURL) == Data("preserve".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: reclaimed.path).isEmpty)
  }

  @Test("Stale reclamation removes nested hardened snapshot entries")
  func staleReclamationRemovesNestedHardenedEntries() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    let retired = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    let nestedURL = URL(fileURLWithPath: retired.path)
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(
      at: nestedURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let executableURL = nestedURL.appendingPathComponent("server")
    try Data("retired".utf8).write(to: executableURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: executableURL.path
    )
    close(retired)

    let reclaimed = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    defer { close(reclaimed) }

    #expect(try FileManager.default.contentsOfDirectory(atPath: reclaimed.path).isEmpty)
  }

  @Test("Repeated EMFILE failures do not permanently consume the fixed slot pool")
  func repeatedPostMkdirEMFILEFailuresDoNotConsumePool() throws {
    let policy = try makePolicy(maximumRetainedSlots: 3)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    for _ in 0..<16 {
      do {
        let directory = try MCPExecutableSnapshot.makePrivateDirectory(
          policy: policy,
          namespaceBasename: namespace,
          openClaimedSlot: Self.failWithTooManyOpenFiles
        )
        Darwin.close(directory.descriptor)
        Darwin.close(directory.parentDescriptor)
        Darwin.close(directory.namespaceParentDescriptor)
        Issue.record("Expected the claimed slot open to fail with EMFILE")
      } catch {
        #expect(error as? MCPClientSessionError == .connectionClosed)
      }
    }
    #expect(openVnodePaths(beneath: namespaceURL.path).isEmpty)

    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespaceURL.path).sorted()
        == ["slot-0000"]
    )
    let recovered = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    defer {
      Darwin.close(recovered.descriptor)
      Darwin.close(recovered.parentDescriptor)
      Darwin.close(recovered.namespaceParentDescriptor)
    }
    #expect(recovered.basename == "slot-0000")
  }

  @Test("A failed slot open never deletes an unrelated pathname replacement")
  func failedSlotOpenPreservesReplacement() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }
    let movedBasename = "moved-owned-slot"

    #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace,
        openClaimedSlot: { parentDescriptor, basename in
          let renamed = movedBasename.withCString { movedName in
            basename.withCString { name in
              renameat(parentDescriptor, name, parentDescriptor, movedName)
            }
          }
          guard renamed == 0 else { return -1 }
          _ = basename.withCString { name in
            mkdirat(parentDescriptor, name, 0o700)
          }
          errno = EMFILE
          return -1
        }
      )
    }

    var replacementStatus = stat()
    var movedStatus = stat()
    #expect(lstat(namespaceURL.appendingPathComponent("slot-0000").path, &replacementStatus) == 0)
    #expect(lstat(namespaceURL.appendingPathComponent(movedBasename).path, &movedStatus) == 0)
    #expect(replacementStatus.st_ino != movedStatus.st_ino)
  }

  @Test("External slot removal makes that fixed name reusable")
  func externalSlotRemovalMakesNameReusable() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace,
        openClaimedSlot: Self.failWithTooManyOpenFiles
      )
    }
    try FileManager.default.removeItem(at: namespaceURL.appendingPathComponent("slot-0000"))

    let directory = try MCPExecutableSnapshot.makePrivateDirectory(
      policy: policy,
      namespaceBasename: namespace
    )
    defer {
      Darwin.close(directory.descriptor)
      Darwin.close(directory.parentDescriptor)
      Darwin.close(directory.namespaceParentDescriptor)
    }
    var namespaceStatus = stat()
    var slotStatus = stat()
    #expect(lstat(namespaceURL.path, &namespaceStatus) == 0)
    #expect(fstat(directory.descriptor, &slotStatus) == 0)
    #expect(namespaceStatus.st_mode & S_IFMT == S_IFDIR)
    #expect(slotStatus.st_mode & S_IFMT == S_IFDIR)
    #expect(namespaceStatus.st_uid == geteuid())
    #expect(slotStatus.st_uid == geteuid())
    #expect(namespaceStatus.st_mode & 0o777 == 0o700)
    #expect(slotStatus.st_mode & 0o777 == 0o700)
  }

  @Test("Post-claim namespace replacement fails without deleting either directory")
  func postClaimNamespaceReplacementFailsClosed() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    let movedNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(namespace).moved",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: namespaceURL)
      try? FileManager.default.removeItem(at: movedNamespaceURL)
    }

    #expect(throws: MCPClientSessionError.connectionClosed) {
      _ = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace,
        openClaimedSlot: { parentDescriptor, basename in
          let descriptor = MCPExecutableSnapshotAdmission.openDirectoryForProduction(
            parentDescriptor: parentDescriptor,
            basename: basename
          )
          guard descriptor >= 0 else { return descriptor }
          guard Darwin.rename(namespaceURL.path, movedNamespaceURL.path) == 0 else {
            return descriptor
          }
          _ = Darwin.mkdir(namespaceURL.path, 0o700)
          return descriptor
        }
      )
    }

    var replacementStatus = stat()
    var movedStatus = stat()
    #expect(lstat(namespaceURL.path, &replacementStatus) == 0)
    #expect(lstat(movedNamespaceURL.path, &movedStatus) == 0)
    #expect(replacementStatus.st_ino != movedStatus.st_ino)
  }

  @Test("Copied-byte admission fails before file materialization")
  func copiedByteAdmissionPrecedesMaterialization() throws {
    let policy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 1,
      maximumEntriesPerSlot: 8,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 8
    )
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }
    let sourceURL = URL(
      fileURLWithPath: "/private/tmp/hex-mcp-admission-source.\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    try Data("#!/bin/sh\n".utf8).write(to: sourceURL, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: sourceURL.path
    )
    let sourceDescriptor = Darwin.open(
      sourceURL.path,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)

    #expect(throws: MCPClientSessionError.limitExceeded) {
      _ = try MCPExecutableSnapshot.create(
        from: sourceDescriptor,
        initialStatus: sourceStatus,
        afterSourceValidation: nil,
        policy: policy,
        namespaceBasename: namespace
      )
    }

    let slotURL = namespaceURL.appendingPathComponent("slot-0000", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: slotURL.path).isEmpty)
  }

  @Test("Snapshot validation detects namespace replacement before execution")
  func snapshotValidationDetectsNamespaceReplacement() throws {
    let policy = try makePolicy(maximumRetainedSlots: 1)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    let movedNamespaceURL = URL(
      fileURLWithPath: "/private/tmp/\(namespace).moved",
      isDirectory: true
    )
    defer {
      try? FileManager.default.removeItem(at: namespaceURL)
      try? FileManager.default.removeItem(at: movedNamespaceURL)
    }
    let sourceURL = URL(
      fileURLWithPath: "/private/tmp/hex-mcp-namespace-source.\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: sourceURL) }
    try Data("#!/bin/sh\nexit 0\n".utf8).write(
      to: sourceURL,
      options: .withoutOverwriting
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: sourceURL.path
    )
    let sourceDescriptor = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)
    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil,
      policy: policy,
      namespaceBasename: namespace
    )

    #expect(Darwin.rename(namespaceURL.path, movedNamespaceURL.path) == 0)
    let replacementSlotURL = namespaceURL.appendingPathComponent(
      "slot-0000",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: replacementSlotURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let replacementBytes = Data("unrelated replacement".utf8)
    let replacementExecutableURL = replacementSlotURL.appendingPathComponent("executable")
    try replacementBytes.write(to: replacementExecutableURL, options: .withoutOverwriting)

    #expect(snapshot?.isIntact() == false)
    snapshot = nil

    #expect(try Data(contentsOf: replacementExecutableURL) == replacementBytes)
    let movedExecutableURL = movedNamespaceURL.appendingPathComponent(
      "slot-0000/executable"
    )
    var movedStatus = stat()
    #expect(lstat(movedExecutableURL.path, &movedStatus) == 0)
    #expect(movedStatus.st_size == 0)
    #expect(movedStatus.st_mode & 0o777 == 0)
  }

  @Test("Entry, pathname, link-target, and copied-byte counters fail closed")
  func perSlotCountersFailClosed() throws {
    let entryPolicy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 1,
      maximumEntriesPerSlot: 1,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 8
    )
    var entryState = MCPExecutableSnapshot.CopyState(policy: entryPolicy)
    try entryState.admitEntry(relativePath: "a", copiedBytes: 0)
    #expect(throws: MCPClientSessionError.limitExceeded) {
      try entryState.admitEntry(relativePath: "b", copiedBytes: 0)
    }
    #expect(entryState.admittedEntryCount == 1)

    let metadataPolicy = try makePolicy(maximumRetainedSlots: 1)
    var metadataState = MCPExecutableSnapshot.CopyState(policy: metadataPolicy)
    try metadataState.admitEntry(
      relativePath: "a",
      additionalPathMetadataBytes: 4_094,
      copiedBytes: 0
    )
    #expect(throws: MCPClientSessionError.limitExceeded) {
      try metadataState.admitEntry(relativePath: "b", copiedBytes: 0)
    }
    #expect(metadataState.pathMetadataByteCount == 4_096)

    let copiedPolicy = try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: 1,
      maximumEntriesPerSlot: 2,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 8
    )
    var copiedState = MCPExecutableSnapshot.CopyState(policy: copiedPolicy)
    try copiedState.admitEntry(relativePath: "a", copiedBytes: 8)
    #expect(throws: MCPClientSessionError.limitExceeded) {
      try copiedState.admitEntry(relativePath: "b", copiedBytes: 1)
    }
    #expect(copiedState.copiedByteCount == 8)
  }

  private static func failWithTooManyOpenFiles(
    parentDescriptor _: Int32,
    basename _: String
  ) -> Int32 {
    errno = EMFILE
    return -1
  }

  private func compileWaitingFixture(at executableURL: URL) throws {
    let sourceURL = executableURL.appendingPathExtension("c")
    try Data(
      "#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".utf8
    ).write(to: sourceURL, options: .withoutOverwriting)
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "clang", sourceURL.path, "-o", executableURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(decoding: errorData.prefix(4_096), as: UTF8.self)
    try #require(
      process.terminationReason == .exit && process.terminationStatus == 0,
      "Fixture compiler failed: \(errorText)"
    )
  }

  private func close(_ directory: MCPExecutableSnapshot.PrivateDirectory) {
    Darwin.close(directory.descriptor)
    Darwin.close(directory.parentDescriptor)
    Darwin.close(directory.namespaceParentDescriptor)
  }

  private func openVnodePaths(beneath rootPath: String) -> [String] {
    let childPathPrefix = rootPath + "/"
    let infoByteCount = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    var matches: [String] = []

    for descriptor in 0..<getdtablesize() {
      var info = vnode_fdinfowithpath()
      guard
        proc_pidfdinfo(
          getpid(),
          descriptor,
          PROC_PIDFDVNODEPATHINFO,
          &info,
          infoByteCount
        ) == infoByteCount
      else {
        continue
      }
      let path = withUnsafePointer(to: &info.pvip.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      if path == rootPath || path.hasPrefix(childPathPrefix) {
        matches.append(path)
      }
    }

    return matches
  }

  private func makePolicy(maximumRetainedSlots: Int) throws -> MCPExecutableSnapshotPolicy {
    try MCPExecutableSnapshotPolicy(
      maximumRetainedSlots: maximumRetainedSlots,
      maximumEntriesPerSlot: 8,
      maximumPathMetadataBytesPerSlot: 4_096,
      maximumCopiedBytesPerSlot: 4_096
    )
  }

  private func uniqueNamespace() -> String {
    ".hex-mcp-admission-tests.\(UUID().uuidString)"
  }
}
