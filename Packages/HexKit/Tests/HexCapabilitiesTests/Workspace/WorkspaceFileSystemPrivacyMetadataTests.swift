import Darwin
import Foundation
import Testing

@testable import HexCapabilities

@Suite("Workspace privacy metadata")
struct WorkspaceFileSystemPrivacyMetadataTests {
  @Test(arguments: [false, true])
  func createsAndReplacesAcrossDirectoriesWithSystemPrivacyMetadata(tracked: Bool) async throws {
    let configuredRoot = ProcessInfo.processInfo.environment["HEX_PRIVACY_METADATA_TEST_ROOT"]
    let parent =
      configuredRoot.map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.temporaryDirectory
    let root = parent.appendingPathComponent("hex-privacy-write-test-\(UUID())")
    let admission = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-privacy-namespace-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: admission)
    }
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw WorkspaceFileSystemError.invalidRoot }
    defer { close(descriptor) }
    let namespace = try WorkspaceWriteTransactionNamespace(
      appropriateFor: root, targetDescriptor: descriptor, admissionDirectoryURL: admission)
    let files = try WorkspaceFileSystem(root: root, writeTransactionNamespace: namespace)
    let created = try await files.writeTextFile(
      "first", at: "document.txt", expectedRevision: nil, relativeTo: nil)
    let destination = root.appendingPathComponent("document.txt")
    if configuredRoot != nil {
      #expect(getxattr(destination.path, "com.apple.macl", nil, 0, 0, 0) >= 0)
    }
    #expect(chmod(destination.path, 0o640) == 0)
    if tracked {
      #expect(chflags(destination.path, UInt32(UF_TRACKED)) == 0)
    }
    let attribute = "com.lunarmoth.hex.test-preserved"
    #expect("value".withCString { setxattr(destination.path, attribute, $0, 5, 0, 0) } == 0)
    let updated = try await files.writeTextFile(
      "second", at: "document.txt", expectedRevision: created.revision, relativeTo: nil)
    let read = try await files.readTextFile(at: "document.txt", relativeTo: nil)
    #expect(read.content == "second")
    #expect(read.revision == updated.revision)
    #expect(read.revision != created.revision)
    var status = stat()
    #expect(lstat(destination.path, &status) == 0)
    #expect(status.st_nlink == 1)
    #expect(status.st_mode & 0o777 == 0o640)
    #expect(status.st_flags & UInt32(UF_TRACKED) == (tracked ? UInt32(UF_TRACKED) : 0))
    var bytes = [UInt8](repeating: 0, count: 5)
    #expect(getxattr(destination.path, attribute, &bytes, bytes.count, 0, 0) == 5)
    #expect(String(decoding: bytes, as: UTF8.self) == "value")
    if configuredRoot != nil {
      #expect(getxattr(destination.path, "com.apple.macl", nil, 0, 0, 0) >= 0)
    }
  }
}
