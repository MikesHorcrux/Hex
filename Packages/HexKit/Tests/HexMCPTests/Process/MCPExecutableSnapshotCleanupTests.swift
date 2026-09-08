import Darwin
import Foundation
import Testing

@testable import HexMCP

@Suite("MCP executable snapshot cleanup", .serialized)
struct MCPExecutableSnapshotCleanupTests {
  @Test("Teardown retains path metadata and truncates its physically owned file")
  func teardownRetainsMetadataAndTruncatesOwnedFile() throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let source = fixtureDirectory.appendingPathComponent("server")
    try writeExecutable(to: source)
    let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    snapshot = nil

    var retainedStatus = stat()
    #expect(lstat(executablePath, &retainedStatus) == 0)
    #expect(retainedStatus.st_mode & S_IFMT == S_IFREG)
    #expect(retainedStatus.st_size == 0)
    #expect(retainedStatus.st_mode & 0o777 == 0)
    #expect(FileManager.default.fileExists(atPath: snapshotRoot.path))
  }

  @Test("Teardown truncates the owned inode without touching a pathname replacement")
  func teardownTruncatesOwnedInodeNotReplacement() throws {
    let fixtureDirectory = try makeFixtureDirectory()
    defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
    let source = fixtureDirectory.appendingPathComponent("server")
    try writeExecutable(to: source)
    let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(sourceDescriptor >= 0)
    guard sourceDescriptor >= 0 else { return }
    defer { Darwin.close(sourceDescriptor) }
    var sourceStatus = stat()
    #expect(fstat(sourceDescriptor, &sourceStatus) == 0)

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }
    let movedOwnedPath = snapshotRoot.appendingPathComponent("moved-owned-executable").path
    #expect(Darwin.rename(executablePath, movedOwnedPath) == 0)
    let replacement = Data("unrelated replacement".utf8)
    #expect(Self.createFile(atPath: executablePath, contents: replacement))

    snapshot = nil

    #expect(try Data(contentsOf: URL(fileURLWithPath: executablePath)) == replacement)
    var movedStatus = stat()
    #expect(lstat(movedOwnedPath, &movedStatus) == 0)
    #expect(movedStatus.st_size == 0)
    #expect(movedStatus.st_mode & 0o777 == 0)
  }

  private func makeFixtureDirectory() throws -> URL {
    let directory = URL(
      fileURLWithPath: "/private/tmp/hex-mcp-cleanup-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func writeExecutable(to url: URL) throws {
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }

  private static func createFile(atPath path: String, contents: Data) -> Bool {
    let descriptor = Darwin.open(
      path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    return contents.withUnsafeBytes { bytes in
      Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count
    }
  }
}
