import Darwin
import Foundation
import Synchronization
import Testing

@testable import HexMCP

@Suite("MCP executable snapshot cleanup", .serialized)
struct MCPExecutableSnapshotCleanupTests {
  @Test("Entry cleanup preserves a replacement installed after identity validation")
  func entryCleanupPreservesFinalWindowReplacement() throws {
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
    let replacement = Data("entry replacement".utf8)
    let mutationSucceeded = Mutex(false)
    let movedBasename = "moved-executable-\(UUID().uuidString)"

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil,
      cleanupAuditHooks: .init(
        afterEntryIdentityValidation: { parentDescriptor, basename in
          guard basename == "executable" else { return }
          let renamed =
            movedBasename.withCString { movedName in
              basename.withCString { name in
                renameat(parentDescriptor, name, parentDescriptor, movedName)
              }
            } == 0
          let descriptor = basename.withCString { name in
            openat(
              parentDescriptor,
              name,
              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              0o600
            )
          }
          guard renamed, descriptor >= 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return
          }
          defer { Darwin.close(descriptor) }
          mutationSucceeded.withLock {
            $0 = replacement.withUnsafeBytes { bytes in
              Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count
            }
          }
        }
      )
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    snapshot = nil

    #expect(mutationSucceeded.withLock { $0 })
    #expect(try Data(contentsOf: URL(fileURLWithPath: executablePath)) == replacement)
    #expect(
      FileManager.default.fileExists(
        atPath: snapshotRoot.appendingPathComponent(movedBasename).path
      )
    )
  }

  @Test("Root cleanup preserves a replacement installed after identity validation")
  func rootCleanupPreservesFinalWindowReplacement() throws {
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
    let mutationSucceeded = Mutex(false)
    let movedBasename = ".hex-mcp-moved-root.\(UUID().uuidString)"

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil,
      cleanupAuditHooks: .init(
        afterRootIdentityValidation: { parentDescriptor, basename in
          let renamed =
            movedBasename.withCString { movedName in
              basename.withCString { name in
                renameat(parentDescriptor, name, parentDescriptor, movedName)
              }
            } == 0
          let replaced =
            basename.withCString { name in
              mkdirat(parentDescriptor, name, 0o700)
            } == 0
          mutationSucceeded.withLock { $0 = renamed && replaced }
        }
      )
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    let movedRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent(movedBasename, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: snapshotRoot)
      try? FileManager.default.removeItem(at: movedRoot)
    }

    snapshot = nil

    #expect(mutationSucceeded.withLock { $0 })
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: snapshotRoot.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try FileManager.default.contentsOfDirectory(atPath: movedRoot.path).isEmpty)
  }

  @Test("Entry cleanup retains a replacement installed at the quarantined unlink window")
  func entryCleanupRetainsQuarantinedFinalWindowReplacement() throws {
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
    let replacement = Data("quarantined entry replacement".utf8)
    let mutationSucceeded = Mutex(false)
    let movedBasename = "moved-quarantined-executable-\(UUID().uuidString)"

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil,
      cleanupAuditHooks: .init(
        afterQuarantinedEntryIdentityValidation: { parentDescriptor, basename in
          let renamed =
            movedBasename.withCString { movedName in
              basename.withCString { name in
                renameat(parentDescriptor, name, parentDescriptor, movedName)
              }
            } == 0
          let descriptor = basename.withCString { name in
            openat(
              parentDescriptor,
              name,
              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              0o600
            )
          }
          guard renamed, descriptor >= 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            return
          }
          defer { Darwin.close(descriptor) }
          mutationSucceeded.withLock {
            $0 = replacement.withUnsafeBytes { bytes in
              Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count
            }
          }
        }
      )
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: snapshotRoot) }

    snapshot = nil

    #expect(mutationSucceeded.withLock { $0 })
    #expect(try Data(contentsOf: URL(fileURLWithPath: executablePath)) == replacement)
    #expect(
      FileManager.default.fileExists(
        atPath: snapshotRoot.appendingPathComponent(movedBasename).path
      )
    )
  }

  @Test("Root cleanup retains a replacement installed at the quarantined rmdir window")
  func rootCleanupRetainsQuarantinedFinalWindowReplacement() throws {
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
    let mutationSucceeded = Mutex(false)
    let movedBasename = ".hex-mcp-moved-quarantined-root.\(UUID().uuidString)"

    var snapshot: MCPExecutableSnapshot? = try MCPExecutableSnapshot.create(
      from: sourceDescriptor,
      initialStatus: sourceStatus,
      afterSourceValidation: nil,
      cleanupAuditHooks: .init(
        afterQuarantinedRootIdentityValidation: { parentDescriptor, basename in
          let renamed =
            movedBasename.withCString { movedName in
              basename.withCString { name in
                renameat(parentDescriptor, name, parentDescriptor, movedName)
              }
            } == 0
          let replaced =
            basename.withCString { name in
              mkdirat(parentDescriptor, name, 0o700)
            } == 0
          mutationSucceeded.withLock { $0 = renamed && replaced }
        }
      )
    )
    let executablePath = try #require(snapshot?.executablePath)
    let snapshotRoot = URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    let movedRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent(movedBasename, isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: snapshotRoot)
      try? FileManager.default.removeItem(at: movedRoot)
    }

    snapshot = nil

    #expect(mutationSucceeded.withLock { $0 })
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: snapshotRoot.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(try FileManager.default.contentsOfDirectory(atPath: movedRoot.path).isEmpty)
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
}
