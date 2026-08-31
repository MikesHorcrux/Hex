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

  @Test("Rejects an image whose unique runpath bytes exceed the per-image budget")
  func rejectsExcessivePerImageRunpathBytes() throws {
    let longRunpath = String(repeating: "x", count: 4_000)
    let image = thinImage(
      commands: (0..<300).map { index in
        pathCommand(
          command: 0x8000_001C,
          path: "@loader_path/\(longRunpath)/\(index)"
        )
      }
    )

    #expect(throws: MCPClientSessionError.connectionClosed) {
      try parseImage(image)
    }
  }

  @Test("Rejects an image whose unique runpath count exceeds the per-image budget")
  func rejectsExcessivePerImageRunpathCount() throws {
    let image = thinImage(
      commands: (0...1_024).map { index in
        pathCommand(command: 0x8000_001C, path: "@loader_path/\(index)")
      }
    )

    #expect(throws: MCPClientSessionError.connectionClosed) {
      try parseImage(image)
    }
  }

  @Test("Enforces closure-wide runpath count and byte budgets")
  func enforcesClosureWideRunpathBudgets() throws {
    let shortRunpaths = (0..<MCPExecutableSnapshot.maximumRunpathsPerImage).map { index in
      MCPExecutableSnapshot.ExpandedRunpath(
        relativePath: "runpath-\(index)",
        isTrustedSystemPath: false,
        isExternalPath: false
      )
    }
    var countState = MCPExecutableSnapshot.CopyState(policy: .standard)
    for _ in 0..<(
      MCPExecutableSnapshot.maximumClosureRunpaths
        / MCPExecutableSnapshot.maximumRunpathsPerImage
    ) {
      try countState.admitRunpathBudget(source: shortRunpaths, snapshot: [])
    }
    #expect(throws: MCPClientSessionError.limitExceeded) {
      try countState.admitRunpathBudget(source: shortRunpaths, snapshot: [])
    }

    let longRunpaths = (0..<240).map { index in
      MCPExecutableSnapshot.ExpandedRunpath(
        relativePath: String(repeating: "x", count: 4_000) + "-\(index)",
        isTrustedSystemPath: false,
        isExternalPath: false
      )
    }
    var byteState = MCPExecutableSnapshot.CopyState(policy: .standard)
    for _ in 0..<8 {
      try byteState.admitRunpathBudget(source: longRunpaths, snapshot: [])
    }
    #expect(throws: MCPClientSessionError.limitExceeded) {
      try byteState.admitRunpathBudget(source: longRunpaths, snapshot: [])
    }
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

  @Test("Keeps a framework target descriptor bound across a pathname swap")
  func frameworkTargetDescriptorSurvivesPathSwap() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-framework-resolution-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let framework = root.appendingPathComponent("MCPFixture.framework", isDirectory: true)
    let versions = framework.appendingPathComponent("Versions", isDirectory: true)
    let version = versions.appendingPathComponent("A", isDirectory: true)
    let target = version.appendingPathComponent("MCPFixture")
    let current = versions.appendingPathComponent("Current")
    try FileManager.default.createDirectory(
      at: version,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try Data("old-target".utf8).write(to: target, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: target.path
    )
    #expect(Darwin.symlink("A", current.path) == 0)
    let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    #expect(rootDescriptor >= 0)
    guard rootDescriptor >= 0 else { return }
    defer { Darwin.close(rootDescriptor) }

    let resolved = try #require(
      try MCPExecutableSnapshot.resolveFrameworkRelativePath(
        parentPath: "MCPFixture.framework/Versions",
        target: "Current/MCPFixture",
        packageRoot: "MCPFixture.framework",
        beneath: rootDescriptor,
        expectedParentDescriptor: nil,
        requireExecutable: false,
        requireRegular: true,
        missingIsAllowed: false
      )
    )
    defer { Darwin.close(resolved.descriptor) }
    var descriptorStatus = stat()
    #expect(fstat(resolved.descriptor, &descriptorStatus) == 0)
    var originalByte = UInt8(0)
    #expect(pread(resolved.descriptor, &originalByte, 1, 0) == 1)

    let replacement = root.appendingPathComponent("replacement")
    try Data("new-target".utf8).write(to: replacement, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500],
      ofItemAtPath: replacement.path
    )
    #expect(Darwin.rename(replacement.path, target.path) == 0)

    var boundByte = UInt8(0)
    var boundStatus = stat()
    #expect(pread(resolved.descriptor, &boundByte, 1, 0) == 1)
    #expect(fstat(resolved.descriptor, &boundStatus) == 0)
    #expect(boundByte == originalByte)
    #expect(boundStatus.st_dev == descriptorStatus.st_dev)
    #expect(boundStatus.st_ino == descriptorStatus.st_ino)
    let reopened = Darwin.open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(reopened >= 0)
    guard reopened >= 0 else { return }
    defer { Darwin.close(reopened) }
    var reopenedStatus = stat()
    #expect(fstat(reopened, &reopenedStatus) == 0)
    #expect(reopenedStatus.st_ino != descriptorStatus.st_ino)
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
