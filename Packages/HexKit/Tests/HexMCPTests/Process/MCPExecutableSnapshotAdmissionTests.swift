import Darwin
import Foundation
import Testing

@testable import HexMCP

@Suite("MCP executable snapshot admission", .serialized)
struct MCPExecutableSnapshotAdmissionTests {
  @Test("Repeated EMFILE failures after mkdir stop at the fixed slot cap")
  func repeatedPostMkdirEMFILEFailuresStopAtSlotCap() throws {
    let policy = try makePolicy(maximumRetainedSlots: 3)
    let namespace = uniqueNamespace()
    let namespaceURL = URL(fileURLWithPath: "/private/tmp/\(namespace)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: namespaceURL) }

    for _ in 0..<policy.maximumRetainedSlots {
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

    #expect(
      try FileManager.default.contentsOfDirectory(atPath: namespaceURL.path).sorted()
        == ["slot-0000", "slot-0001", "slot-0002"]
    )
    let expectedUsage = MCPExecutableSnapshotNamespaceUsage(
      namespacePath: namespaceURL.path,
      retainedSlotCount: 3,
      policy: policy
    )
    #expect(
      throws: MCPExecutableSnapshotAdmissionError.namespaceExhausted(expectedUsage)
    ) {
      _ = try MCPExecutableSnapshot.makePrivateDirectory(
        policy: policy,
        namespaceBasename: namespace,
        openClaimedSlot: Self.failWithTooManyOpenFiles
      )
    }
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
