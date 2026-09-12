import Darwin
import Foundation
import Testing

@testable import HexCapabilities

@Suite("Workspace compression metadata")
struct WorkspaceFileSystemCompressionMetadataTests {
  @Test
  func publicationToleratesCompressionBookkeepingWithoutLosingContentOrUserMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-compression-\(UUID())")
    let admission = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-compression-namespace-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: admission)
    }
    let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard rootDescriptor >= 0 else { throw WorkspaceFileSystemError.invalidRoot }
    defer { close(rootDescriptor) }
    let namespace = try WorkspaceWriteTransactionNamespace(
      appropriateFor: root, targetDescriptor: rootDescriptor, admissionDirectoryURL: admission)
    let target = root.appendingPathComponent("document.txt")
    let files = try WorkspaceFileSystem(
      root: root, replacementPublicationHook: nil,
      replacementPostSwapHook: {
        // Simulate the system adding its private compression representation after publication.
        // UF_COMPRESSED remains unset: the ordinary data fork is still authoritative.
        let header: [UInt8] = [0x66, 0x70, 0x6d, 0x63, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let result = header.withUnsafeBytes { bytes in
          setxattr(
            target.path, "com.apple.decmpfs", bytes.baseAddress, bytes.count, 0,
            XATTR_SHOWCOMPRESSION)
        }
        guard result == 0 else { throw WorkspaceFileSystemError.ioFailure }
      }, writeTransactionNamespace: namespace)
    let original = try await files.writeTextFile(
      "original", at: "document.txt", expectedRevision: nil, relativeTo: nil)
    #expect(chmod(target.path, 0o640) == 0)
    let attribute = "com.lunarmoth.hex.preserved"
    #expect("value".withCString { setxattr(target.path, attribute, $0, 5, 0, 0) } == 0)
    let updated = try await files.writeTextFile(
      "replacement", at: "document.txt", expectedRevision: original.revision, relativeTo: nil)
    let read = try await files.readTextFile(at: "document.txt", relativeTo: nil)
    #expect(read.content == "replacement")
    #expect(read.revision == updated.revision)
    var status = stat()
    #expect(lstat(target.path, &status) == 0)
    #expect(status.st_nlink == 1)
    #expect(status.st_mode & 0o777 == 0o640)
    #expect(status.st_flags & UInt32(UF_COMPRESSED) == 0)
    var bytes = [UInt8](repeating: 0, count: 5)
    #expect(getxattr(target.path, attribute, &bytes, bytes.count, 0, 0) == 5)
    #expect(String(decoding: bytes, as: UTF8.self) == "value")
  }
}
