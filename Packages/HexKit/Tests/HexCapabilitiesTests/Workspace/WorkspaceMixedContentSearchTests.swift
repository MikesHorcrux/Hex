import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Workspace mixed-content search")
struct WorkspaceMixedContentSearchTests {
  @Test
  func largeAssetDoesNotDiscardCodeMatches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("let wanted = 1".utf8).write(to: root.appendingPathComponent("a.swift"))
    try Data(repeating: 0xFF, count: 600 * 1_024).write(to: root.appendingPathComponent("z.png"))
    let tool = WorkspaceSearchTextTool(fileSystem: try WorkspaceFileSystem(root: root))
    let result = try await tool.execute(
      ToolCall(
        name: "workspace_search_text",
        arguments: ["path": .string("."), "query": .string("wanted")]),
      in: ToolExecutionContext(runID: AgentRunID(), workingDirectory: root))
    #expect(result.status == .success)
    guard case .object(let output) = result.output else {
      Issue.record("Expected search result object")
      return
    }
    guard case .array(let matches) = output["matches"] else {
      Issue.record("Expected preserved code matches")
      return
    }
    #expect(matches.count == 1)
    #expect(output["skipped_oversized_files"] == .integer(1))
  }

  @Test
  func skippedOversizedFilesStillConsumeTheGlobalFileBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0xFF, count: 16).write(to: root.appendingPathComponent("a.png"))
    try Data("wanted".utf8).write(to: root.appendingPathComponent("z.swift"))
    let fileSystem = try WorkspaceFileSystem(
      root: root,
      configuration: WorkspaceFileSystemConfiguration(maximumReadBytes: 8, maximumSearchFiles: 1))

    await #expect(throws: WorkspaceFileSystemError.capacityExceeded) {
      _ = try await fileSystem.searchTextReport("wanted", under: ".", relativeTo: nil)
    }
  }

  @Test
  func dependencyExclusionIsExplicitAndCanBeOverridden() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dependencies = root.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("wanted".utf8).write(to: dependencies.appendingPathComponent("a.js"))
    let standard = try WorkspaceFileSystem(root: root)
    let included = try WorkspaceFileSystem(
      root: root,
      configuration: WorkspaceFileSystemConfiguration(excludedSearchDirectoryNames: []))

    let standardReport = try await standard.searchTextReport("wanted", under: ".", relativeTo: nil)
    let includedReport = try await included.searchTextReport("wanted", under: ".", relativeTo: nil)
    #expect(standardReport.matches.isEmpty)
    #expect(includedReport.matches.map(\.path) == ["node_modules/a.js"])
    #expect(includedReport.skippedOversizedFiles == 0)
  }
}
