import Darwin
import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Immutable file artifact storage")
struct FileArtifactStoreTests {
  @Test
  func macOSTemporaryDirectoryAliasIsPinnedWithoutFoundationRenormalization() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("alias-safe".utf8), metadata: metadata())
    let directory = try FileArtifactDirectory(url: fixture.root.standardizedFileURL)
    if fixture.root.path.hasPrefix("/var/") {
      #expect(directory.canonicalPath.hasPrefix("/private/var/"))
    }
    let reopened = try FileArtifactStore(rootURL: fixture.root.standardizedFileURL)
    #expect(
      try await reopened.read(reference, offset: 0, maximumBytes: 32).data
        == Data("alias-safe".utf8))
  }

  @Test
  func nestedRootAndLargeOutputSurviveReopenWithBoundedRanges() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let root = fixture.directory.appendingPathComponent("fresh/nested/artifacts")
    let store = try FileArtifactStore(rootURL: root)
    let data = Data((0..<(1_024 * 1_024 + 73)).map { UInt8($0 % 251) })
    let session = try await store.begin(metadata())
    try await session.append(Data(data.prefix(500_000)))
    try await session.append(Data(data.dropFirst(500_000)))
    let reference = try await session.finish(isComplete: true)
    #expect(reference.byteCount == Int64(data.count))
    #expect(reference.isComplete)

    let reopened = try FileArtifactStore(rootURL: root)
    let first = try await reopened.read(reference, offset: 0, maximumBytes: 1_024 * 1_024)
    #expect(first.data == data.prefix(1_024 * 1_024))
    let nextOffset: Int64 = try #require(first.nextOffset)
    let expectedOffset: Int64 = 1_024 * 1_024
    #expect(nextOffset == expectedOffset)
    let last = try await reopened.read(reference, offset: 1_024 * 1_024, maximumBytes: 128)
    #expect(last.data == data.suffix(73))
    #expect(last.nextOffset == nil)
    let end = try await reopened.read(reference, offset: reference.byteCount, maximumBytes: 1)
    #expect(end.data.isEmpty && end.nextOffset == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: root.path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test
  func quotaRejectionAcceptsNoneOfTheChunkAndAllowsPartialCommit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(
      rootURL: fixture.root, maximumArtifactBytes: 8, maximumTotalBytes: 16)
    let session = try await store.begin(metadata())
    try await session.append(Data("prefix".utf8))
    await #expect(throws: ArtifactStoreError.quotaExceeded) {
      try await session.append(Data("overflow".utf8))
    }
    let reference = try await session.finish(isComplete: false)
    #expect(reference.byteCount == 6)
    #expect(!reference.isComplete)
    #expect(
      try await store.read(reference, offset: 0, maximumBytes: 16).data == Data("prefix".utf8))
    #expect(try await session.finish(isComplete: false) == reference)
    await #expect(throws: ArtifactStoreError.invalidRequest) {
      try await session.finish(isComplete: true)
    }
  }

  @Test
  func concurrentStoreInstancesCannotOversubscribeTheSharedQuota() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let first = try FileArtifactStore(
      rootURL: fixture.root, maximumArtifactBytes: 8, maximumTotalBytes: 10)
    let second = try FileArtifactStore(
      rootURL: fixture.root, maximumArtifactBytes: 8, maximumTotalBytes: 10)
    let left = try await first.begin(metadata())
    let right = try await second.begin(metadata())
    async let leftAccepted = acceptsSixBytes(left)
    async let rightAccepted = acceptsSixBytes(right)
    let (leftResult, rightResult) = try await (leftAccepted, rightAccepted)
    #expect(leftResult != rightResult)
    let leftReference = try await left.finish(isComplete: leftResult)
    let rightReference = try await right.finish(isComplete: rightResult)
    #expect(leftReference.byteCount + rightReference.byteCount == 6)
  }

  @Test
  func cancellationCannotEraseTheKnownFinishedOutput() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let session = try await store.begin(metadata())
    try await session.append(Data("abc".utf8))
    let finish = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.finish(isComplete: true)
    }
    let reference = try await finish.value
    #expect(reference.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    await session.abandon()
    let reopened = try FileArtifactStore(rootURL: fixture.root)
    #expect(try await reopened.read(reference, offset: 0, maximumBytes: 3).data == Data("abc".utf8))
  }

  @Test
  func cancelledAppendDoesNotAcceptItsChunk() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let session = try await store.begin(metadata())
    try await session.append(Data("kept".utf8))
    let append = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await session.append(Data("not accepted".utf8))
    }
    await #expect(throws: CancellationError.self) { try await append.value }
    let reference = try await session.finish(isComplete: false)
    #expect(reference.byteCount == 4)
  }

  @Test
  func abandonedCrashResidueRemainsQuotaAccountedAfterReopen() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(
      rootURL: fixture.root, maximumArtifactBytes: 8, maximumTotalBytes: 8)
    let session = try await store.begin(metadata())
    try await session.append(Data(repeating: 1, count: 8))
    await session.abandon()
    let reopened = try FileArtifactStore(
      rootURL: fixture.root, maximumArtifactBytes: 8, maximumTotalBytes: 8)
    let next = try await reopened.begin(metadata())
    await #expect(throws: ArtifactStoreError.quotaExceeded) {
      try await next.append(Data([2]))
    }
    await next.abandon()
  }

  @Test
  func suppliedReferenceMustMatchEveryManifestField() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let original = try await store.store(Data("abc".utf8), metadata: metadata())
    let changed = ArtifactReference(
      id: original.id, runID: AgentRunID(), toolCallID: original.toolCallID,
      mediaType: original.mediaType, byteCount: original.byteCount, sha256: original.sha256,
      isComplete: original.isComplete)
    await #expect(throws: ArtifactStoreError.corrupt) {
      try await store.read(changed, offset: 0, maximumBytes: 3)
    }
  }

  @Test
  func modifiedBlobIsDetectedEvenAfterAReadWasCached() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("abc".utf8), metadata: metadata())
    _ = try await store.read(reference, offset: 0, maximumBytes: 3)
    let blob = fixture.blob(reference)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: blob.path)
    try Data("abd".utf8).write(to: blob)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o400)], ofItemAtPath: blob.path)
    await #expect(throws: ArtifactStoreError.corrupt) {
      try await store.read(reference, offset: 0, maximumBytes: 3)
    }
  }

  @Test
  func hardLinkedBlobIsRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("abc".utf8), metadata: metadata())
    try FileManager.default.linkItem(
      at: fixture.blob(reference), to: fixture.directory.appendingPathComponent("alias"))
    await #expect(throws: ArtifactStoreError.corrupt) {
      try await store.read(reference, offset: 0, maximumBytes: 3)
    }
  }

  @Test
  func symbolicBlobAliasAndSymlinkAncestorAreRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("abc".utf8), metadata: metadata())
    let moved = fixture.directory.appendingPathComponent("preserved")
    try FileManager.default.moveItem(at: fixture.blob(reference), to: moved)
    try FileManager.default.createSymbolicLink(
      at: fixture.blob(reference), withDestinationURL: moved)
    await #expect(throws: ArtifactStoreError.self) {
      try await store.read(reference, offset: 0, maximumBytes: 3)
    }
    let alias = fixture.directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    #expect(throws: ArtifactStoreError.self) {
      try FileArtifactStore(rootURL: alias.appendingPathComponent("nested"))
    }
    #expect(try Data(contentsOf: moved) == Data("abc".utf8))
  }

  @Test
  func replacingTheRootDoesNotRetargetAnExistingStore() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("abc".utf8), metadata: metadata())
    try FileManager.default.moveItem(
      at: fixture.root, to: fixture.directory.appendingPathComponent("preserved-root"))
    try FileManager.default.createDirectory(
      at: fixture.root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    await #expect(throws: ArtifactStoreError.corrupt) {
      try await store.read(reference, offset: 0, maximumBytes: 3)
    }
  }

  @Test
  func unknownManifestFieldsAndMissingPayloadFailClosed() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("abc".utf8), metadata: metadata())
    let manifest = fixture.root.appendingPathComponent(
      reference.id.uuidString.lowercased() + ".json")
    let original = try Data(contentsOf: manifest)
    var value = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
    value["futureSchema"] = true
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: manifest.path)
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: manifest)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o400)], ofItemAtPath: manifest.path)
    await #expect(throws: ArtifactStoreError.corrupt) {
      try await store.read(reference, offset: 0, maximumBytes: 3)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: manifest.path)
    try original.write(to: manifest)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o400)], ofItemAtPath: manifest.path)
    try FileManager.default.removeItem(at: fixture.blob(reference))
    await #expect(throws: ArtifactStoreError.unavailable) {
      try await store.read(reference, offset: 0, maximumBytes: 3)
    }
  }

  @Test
  func rangeAndConfigurationBoundsAreExplicit() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    #expect(throws: ArtifactStoreError.invalidRequest) {
      try FileArtifactStore(rootURL: fixture.root, maximumArtifactBytes: 2, maximumTotalBytes: 1)
    }
    let store = try FileArtifactStore(rootURL: fixture.root)
    let reference = try await store.store(Data("abc".utf8), metadata: metadata())
    for (offset, count) in [(Int64(-1), 1), (4, 1), (0, 0), (0, 1_024 * 1_024 + 1)] {
      await #expect(throws: ArtifactStoreError.invalidRequest) {
        try await store.read(reference, offset: offset, maximumBytes: count)
      }
    }
  }

  private func metadata() -> ArtifactMetadata {
    ArtifactMetadata(
      runID: AgentRunID(), toolCallID: ToolCallID(rawValue: "output"), mediaType: "text/plain")
  }

  private func acceptsSixBytes(_ session: any ArtifactWriteSession) async throws -> Bool {
    do {
      try await session.append(Data(repeating: 1, count: 6))
      return true
    } catch ArtifactStoreError.quotaExceeded { return false }
  }

  private struct Fixture {
    let directory: URL
    var root: URL { directory.appendingPathComponent("artifacts") }

    init() throws {
      directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("hex-artifact-test-" + UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    }

    func blob(_ reference: ArtifactReference) -> URL {
      root.appendingPathComponent(reference.id.uuidString.lowercased() + ".blob")
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
  }
}
