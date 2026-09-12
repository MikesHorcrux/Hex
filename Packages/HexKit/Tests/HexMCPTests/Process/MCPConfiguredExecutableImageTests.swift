import Darwin
import Foundation
import Synchronization
import Testing

@testable import HexMCP

@Suite("MCP configured executable image validation")
struct MCPConfiguredExecutableImageTests {
  @Test("Rejects an absolute-interpreter text script")
  func rejectsAbsoluteInterpreterScript() throws {
    try expectRejected(Data("#!/private/tmp/mcp-interpreter\n".utf8))
  }

  @Test("Rejects a script before snapshot or execution selection")
  func rejectsScriptBeforeProcessSelection() throws {
    let fixture = try makeExecutableFile(
      bytes: Data("#!/private/tmp/mcp-interpreter\n".utf8)
    )
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try expectRejectedBeforeProcessSelection(fixture.executable)
  }

  @Test("Rejects a trusted-path root-owned script before direct launch")
  func rejectsTrustedRootOwnedScriptBeforeDirectLaunch() throws {
    try expectRejectedBeforeProcessSelection(
      URL(fileURLWithPath: "/usr/bin/gem")
    )
  }

  private func expectRejectedBeforeProcessSelection(_ executable: URL) throws {
    let snapshotSelectionReached = Mutex(false)
    let executionSelectionReached = Mutex(false)
    let configuration = try MCPServerConfiguration(
      serverID: "script-fixture",
      executableURL: executable,
      arguments: [],
      workingDirectory: URL(fileURLWithPath: "/"),
      environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(throws: MCPServerConfigurationError.invalidExecutable) {
      _ = try MCPStdioProcessSpawner.spawn(
        configuration,
        afterSourceValidation: { _ in
          snapshotSelectionReached.withLock { $0 = true }
        },
        beforeExecution: { _, _ in
          executionSelectionReached.withLock { $0 = true }
        }
      )
    }
    #expect(!snapshotSelectionReached.withLock { $0 })
    #expect(!executionSelectionReached.withLock { $0 })
  }

  @Test("Rejects an env-dispatched text script")
  func rejectsEnvironmentDispatchedScript() throws {
    try expectRejected(Data("#!/usr/bin/env sh\n".utf8))
  }

  @Test("Accepts an installed Mach-O executable")
  func acceptsInstalledMachOExecutable() throws {
    try validateExecutable(at: URL(fileURLWithPath: "/usr/bin/true"))
  }

  @Test("Accepts every supported thin and fat Mach-O encoding")
  func acceptsSupportedMachOEncodings() throws {
    let thin32Little = thinImage(
      magic: [0xCE, 0xFA, 0xED, 0xFE],
      uses64BitHeader: false
    )
    let thin64Little = thinImage(
      magic: [0xCF, 0xFA, 0xED, 0xFE],
      uses64BitHeader: true
    )
    let thin32Big = thinImage(
      magic: [0xFE, 0xED, 0xFA, 0xCE],
      uses64BitHeader: false
    )
    let thin64Big = thinImage(
      magic: [0xFE, 0xED, 0xFA, 0xCF],
      uses64BitHeader: true
    )
    let images = [
      thin32Little,
      thin64Little,
      thin32Big,
      thin64Big,
      fatImage(
        magic: [0xCA, 0xFE, 0xBA, 0xBE],
        order: .big,
        uses64BitOffsets: false,
        slice: thin64Little
      ),
      fatImage(
        magic: [0xBE, 0xBA, 0xFE, 0xCA],
        order: .little,
        uses64BitOffsets: false,
        slice: thin64Little
      ),
      fatImage(
        magic: [0xCA, 0xFE, 0xBA, 0xBF],
        order: .big,
        uses64BitOffsets: true,
        slice: thin64Little
      ),
      fatImage(
        magic: [0xBF, 0xBA, 0xFE, 0xCA],
        order: .little,
        uses64BitOffsets: true,
        slice: thin64Little
      ),
    ]

    for image in images {
      try validateExecutable(bytes: image)
    }
  }

  private func expectRejected(_ bytes: Data) throws {
    #expect(throws: MCPServerConfigurationError.invalidExecutable) {
      try validateExecutable(bytes: bytes)
    }
  }

  private func validateExecutable(bytes: Data) throws {
    let fixture = try makeExecutableFile(bytes: bytes)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try validateExecutable(at: fixture.executable)
  }

  private func makeExecutableFile(bytes: Data) throws -> (directory: URL, executable: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-mcp-image-validation-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    do {
      let executable = directory.appendingPathComponent("server")
      try bytes.write(to: executable, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
      )
      return (directory, executable)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  private func validateExecutable(at executable: URL) throws {
    let descriptor = Darwin.open(
      executable.path,
      O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    try MCPStdioProcessSpawner.validateExecutableImage(descriptor, status: status)
  }

  private func thinImage(
    magic: [UInt8],
    uses64BitHeader: Bool
  ) -> Data {
    var image = Data(magic)
    image.append(Data(repeating: 0, count: (uses64BitHeader ? 32 : 28) - magic.count))
    return image
  }

  private func fatImage(
    magic: [UInt8],
    order: ByteOrder,
    uses64BitOffsets: Bool,
    slice: Data
  ) -> Data {
    let tableSize = uses64BitOffsets ? 32 : 20
    let sliceOffset = 8 + tableSize
    var image = Data(magic)
    appendUInt32(1, order: order, to: &image)
    appendUInt32(0, order: order, to: &image)
    appendUInt32(0, order: order, to: &image)
    if uses64BitOffsets {
      appendUInt64(UInt64(sliceOffset), order: order, to: &image)
      appendUInt64(UInt64(slice.count), order: order, to: &image)
      appendUInt32(0, order: order, to: &image)
      appendUInt32(0, order: order, to: &image)
    } else {
      appendUInt32(UInt32(sliceOffset), order: order, to: &image)
      appendUInt32(UInt32(slice.count), order: order, to: &image)
      appendUInt32(0, order: order, to: &image)
    }
    image.append(slice)
    return image
  }

  private func appendUInt32(
    _ value: UInt32,
    order: ByteOrder,
    to data: inout Data
  ) {
    let bytes = [
      UInt8(truncatingIfNeeded: value >> 24),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value),
    ]
    if order == .big {
      data.append(contentsOf: bytes)
    } else {
      data.append(contentsOf: bytes.reversed())
    }
  }

  private func appendUInt64(
    _ value: UInt64,
    order: ByteOrder,
    to data: inout Data
  ) {
    let bytes = [
      UInt8(truncatingIfNeeded: value >> 56),
      UInt8(truncatingIfNeeded: value >> 48),
      UInt8(truncatingIfNeeded: value >> 40),
      UInt8(truncatingIfNeeded: value >> 32),
      UInt8(truncatingIfNeeded: value >> 24),
      UInt8(truncatingIfNeeded: value >> 16),
      UInt8(truncatingIfNeeded: value >> 8),
      UInt8(truncatingIfNeeded: value),
    ]
    if order == .big {
      data.append(contentsOf: bytes)
    } else {
      data.append(contentsOf: bytes.reversed())
    }
  }

  private enum ByteOrder {
    case little
    case big
  }
}
