import Foundation
import HexCapabilities
import Testing

@Suite("Workspace file-system search")
struct WorkspaceFileSystemSearchTests {
  @Test
  func searchesRegularUTF8FilesInStableOrderWithoutFollowingSymlinks() async throws {
    let container = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-search-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let root = container.appending(path: "root", directoryHint: .isDirectory)
    let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    try Data("needle one\nnone".utf8).write(to: root.appending(path: "b.swift"))
    try Data("first\nneedle two".utf8).write(to: nested.appending(path: "a.swift"))
    let outside = container.appending(path: "outside.swift")
    try Data("needle secret".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appending(path: "linked.swift"),
      withDestinationURL: outside
    )
    let fileSystem = try WorkspaceFileSystem(root: root)

    let matches = try await fileSystem.searchText("needle", under: ".", relativeTo: nil)

    #expect(matches.map(\.path) == ["Nested/a.swift", "b.swift"])
    #expect(matches.map(\.line) == [2, 1])
    #expect(matches.map(\.text) == ["needle two", "needle one"])
  }

  @Test
  func failsClosedInsteadOfReturningAQuietlyTruncatedSearch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-search-limit-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x\nx".utf8).write(to: root.appending(path: "a.swift"))
    let configuration = try WorkspaceFileSystemConfiguration(maximumSearchMatches: 1)
    let fileSystem = try WorkspaceFileSystem(root: root, configuration: configuration)

    await #expect(throws: WorkspaceFileSystemError.capacityExceeded) {
      _ = try await fileSystem.searchText("x", under: ".", relativeTo: nil)
    }
  }

  @Test
  func boundsUTF8ExcerptsByBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-search-excerpt-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(("needle" + String(repeating: "🧠", count: 1_000)).utf8).write(
      to: root.appending(path: "long.swift")
    )
    let fileSystem = try WorkspaceFileSystem(root: root)

    let matches = try await fileSystem.searchText("needle", under: ".", relativeTo: nil)

    #expect(matches.count == 1)
    #expect(matches[0].isTruncated)
    #expect(matches[0].text.utf8.count <= 1_024)
  }

  @Test
  func boundsGlobalTraversalAcrossDirectoryOnlyTrees() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "hex-workspace-search-traversal-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    var directory = root
    for index in 0..<8 {
      directory.append(path: "level-\(index)", directoryHint: .isDirectory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try WorkspaceFileSystemConfiguration(maximumSearchEntries: 4)
    let fileSystem = try WorkspaceFileSystem(root: root, configuration: configuration)

    await #expect(throws: WorkspaceFileSystemError.capacityExceeded) {
      _ = try await fileSystem.searchText("needle", under: ".", relativeTo: nil)
    }
  }
}
