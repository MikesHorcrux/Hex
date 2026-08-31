import Darwin
import Foundation
import Testing

@testable import HexMCP

@Suite("MCP executable snapshot bounds", .serialized)
struct MCPExecutableSnapshotTests {
  @Test("Parses and merges bounded fat Mach-O dependency graphs")
  func parsesFatMachODependencyGraph() throws {
    let firstSlice = thinImage(
      commands: [
        dylibCommand(command: 0x0000_000C, path: "@rpath/libA.dylib"),
        pathCommand(command: 0x8000_001C, path: "@loader_path/../Frameworks"),
      ]
    )
    let secondSlice = thinImage(
      commands: [
        dylibCommand(command: 0x8000_0018, path: "@rpath/libA.dylib"),
        dylibCommand(command: 0x8000_001F, path: "@rpath/libB.dylib"),
        pathCommand(command: 0x8000_001C, path: "@executable_path/../Frameworks"),
      ]
    )

    let image = try #require(try parseImage(fatImage(slices: [firstSlice, secondSlice])))

    #expect(
      image.dependencies == [
        MCPMachOImage.Dependency(path: "@rpath/libA.dylib", isRequired: true),
        MCPMachOImage.Dependency(path: "@rpath/libB.dylib", isRequired: true),
      ]
    )
    #expect(
      image.runpaths == [
        "@loader_path/../Frameworks",
        "@executable_path/../Frameworks",
      ]
    )
  }

  @Test("Rejects malformed thin and fat Mach-O bounds")
  func rejectsMalformedMachOBounds() throws {
    var misalignedCommand = thinImage(
      commands: [dylibCommand(command: 0x0000_000C, path: "@rpath/libA.dylib")]
    )
    replaceLittleUInt32(6, at: 36, in: &misalignedCommand)

    var unterminatedPath = thinImage(
      commands: [dylibCommand(command: 0x0000_000C, path: "A")]
    )
    let commandSize = Int(readLittleUInt32(unterminatedPath, at: 36))
    for index in (32 + 24)..<(32 + commandSize) {
      unterminatedPath[index] = 0x41
    }

    var excessiveLoadCommands = thinImage(commands: [])
    replaceLittleUInt32(4_097, at: 16, in: &excessiveLoadCommands)

    var excessiveArchitectures = Data([0xCA, 0xFE, 0xBA, 0xBE])
    appendBigUInt32(65, to: &excessiveArchitectures)

    var outOfBoundsSlice = fatImage(slices: [thinImage(commands: [])])
    replaceBigUInt32(UInt32.max, at: 16, in: &outOfBoundsSlice)

    for malformed in [
      misalignedCommand,
      unterminatedPath,
      excessiveLoadCommands,
      excessiveArchitectures,
      outOfBoundsSlice,
    ] {
      #expect(throws: MCPClientSessionError.connectionClosed) {
        try parseImage(malformed)
      }
    }
  }

  @Test("Enforces aggregate byte, entry, and image bounds at their edges")
  func enforcesAggregateBounds() {
    let maximumBytes = MCPExecutableSnapshot.maximumBundleBytes
    #expect(
      MCPExecutableSnapshot.nextBundleByteCount(
        current: maximumBytes - 1,
        adding: 1
      ) == maximumBytes
    )
    #expect(
      MCPExecutableSnapshot.nextBundleByteCount(
        current: maximumBytes,
        adding: 1
      ) == nil
    )
    #expect(
      MCPExecutableSnapshot.nextBundleByteCount(
        current: off_t.max,
        adding: 1
      ) == nil
    )
    #expect(MCPExecutableSnapshot.nextBundleByteCount(current: -1, adding: 1) == nil)

    #expect(
      MCPExecutableSnapshot.canCreateBundleEntry(
        currentCount: MCPExecutableSnapshot.maximumBundleEntries - 1
      )
    )
    #expect(
      !MCPExecutableSnapshot.canCreateBundleEntry(
        currentCount: MCPExecutableSnapshot.maximumBundleEntries
      )
    )
    #expect(!MCPExecutableSnapshot.canCreateBundleEntry(currentCount: -1))

    #expect(
      MCPExecutableSnapshot.isAcceptableBundleImageCount(
        MCPExecutableSnapshot.maximumBundleImages
      )
    )
    #expect(
      !MCPExecutableSnapshot.isAcceptableBundleImageCount(
        MCPExecutableSnapshot.maximumBundleImages + 1
      )
    )
    #expect(!MCPExecutableSnapshot.isAcceptableBundleImageCount(0))
  }

  @Test("Enforces snapshot path byte, component, and depth bounds")
  func enforcesPathBounds() {
    let maximumDepthPath = Array(
      repeating: "x",
      count: MCPExecutableSnapshot.maximumSnapshotPathDepth
    ).joined(separator: "/")
    let excessiveDepthPath = maximumDepthPath + "/x"
    #expect(
      MCPExecutableSnapshot.normalizeRelativePath(
        maximumDepthPath,
        relativeTo: ""
      ) == maximumDepthPath
    )
    #expect(
      MCPExecutableSnapshot.normalizeRelativePath(
        excessiveDepthPath,
        relativeTo: ""
      ) == nil
    )

    let exactByteComponents =
      Array(repeating: String(repeating: "a", count: 255), count: 15)
      + [String(repeating: "b", count: 254), "c"]
    let exactBytePath = exactByteComponents.joined(separator: "/")
    #expect(exactBytePath.utf8.count == MCPExecutableSnapshot.maximumSnapshotPathBytes)
    #expect(
      MCPExecutableSnapshot.normalizeRelativePath(
        exactBytePath,
        relativeTo: ""
      ) == exactBytePath
    )
    #expect(
      MCPExecutableSnapshot.normalizeRelativePath(
        exactBytePath + "d",
        relativeTo: ""
      ) == nil
    )
    #expect(
      MCPExecutableSnapshot.normalizeRelativePath(
        String(repeating: "x", count: 256),
        relativeTo: ""
      ) == nil
    )
  }

  private func parseImage(_ bytes: Data) throws -> MCPMachOImage? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-macho-tests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("image")
    try bytes.write(to: file, options: .withoutOverwriting)
    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw MCPClientSessionError.connectionClosed }
    defer { Darwin.close(descriptor) }
    return try MCPMachOImage.read(from: descriptor, fileSize: off_t(bytes.count))
  }

  private func thinImage(commands: [Data]) -> Data {
    var image = Data([0xCF, 0xFA, 0xED, 0xFE])
    appendLittleUInt32(0, to: &image)
    appendLittleUInt32(0, to: &image)
    appendLittleUInt32(0, to: &image)
    appendLittleUInt32(UInt32(commands.count), to: &image)
    appendLittleUInt32(UInt32(commands.reduce(0) { $0 + $1.count }), to: &image)
    appendLittleUInt32(0, to: &image)
    appendLittleUInt32(0, to: &image)
    for command in commands { image.append(command) }
    return image
  }

  private func dylibCommand(command: UInt32, path: String) -> Data {
    makePathCommand(command: command, path: path, pathOffset: 24)
  }

  private func pathCommand(command: UInt32, path: String) -> Data {
    makePathCommand(command: command, path: path, pathOffset: 12)
  }

  private func makePathCommand(command: UInt32, path: String, pathOffset: Int) -> Data {
    let unpaddedSize = pathOffset + path.utf8.count + 1
    let commandSize = (unpaddedSize + 3) & ~3
    var bytes = Data()
    appendLittleUInt32(command, to: &bytes)
    appendLittleUInt32(UInt32(commandSize), to: &bytes)
    appendLittleUInt32(UInt32(pathOffset), to: &bytes)
    bytes.append(Data(repeating: 0, count: pathOffset - bytes.count))
    bytes.append(contentsOf: path.utf8)
    bytes.append(0)
    bytes.append(Data(repeating: 0, count: commandSize - bytes.count))
    return bytes
  }

  private func fatImage(slices: [Data]) -> Data {
    var image = Data([0xCA, 0xFE, 0xBA, 0xBE])
    appendBigUInt32(UInt32(slices.count), to: &image)
    var nextOffset = 8 + (20 * slices.count)
    for slice in slices {
      appendBigUInt32(0, to: &image)
      appendBigUInt32(0, to: &image)
      appendBigUInt32(UInt32(nextOffset), to: &image)
      appendBigUInt32(UInt32(slice.count), to: &image)
      appendBigUInt32(0, to: &image)
      nextOffset += slice.count
    }
    for slice in slices { image.append(slice) }
    return image
  }

  private func appendLittleUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 24))
  }

  private func appendBigUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(truncatingIfNeeded: value >> 24))
    data.append(UInt8(truncatingIfNeeded: value >> 16))
    data.append(UInt8(truncatingIfNeeded: value >> 8))
    data.append(UInt8(truncatingIfNeeded: value))
  }

  private func replaceLittleUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data.replaceSubrange(
      offset..<(offset + 4),
      with: [
        UInt8(truncatingIfNeeded: value),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 24),
      ])
  }

  private func replaceBigUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
    data.replaceSubrange(
      offset..<(offset + 4),
      with: [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
      ])
  }

  private func readLittleUInt32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].enumerated().reduce(0) {
      $0 | UInt32($1.element) << (8 * $1.offset)
    }
  }
}
