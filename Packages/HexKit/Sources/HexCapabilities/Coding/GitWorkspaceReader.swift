import CryptoKit
import Foundation
import HexCore

/// Fixed Git read operations with optional locks, helpers, pager, textconv and configured filters
/// disabled. The model cannot select commands, configuration or environment.
struct GitWorkspaceReader: Sendable {
  let fileSystem: WorkspaceFileSystem
  let executor: any ProcessExecuting

  init(fileSystem: WorkspaceFileSystem) throws {
    self.fileSystem = fileSystem
    executor = POSIXProcessExecutor(
      configuration: try ProcessExecutionConfiguration(maximumOutputBytes: 2 * 1_024 * 1_024))
  }

  func snapshot(workspace: URL) async throws -> GitWorkspaceSnapshot {
    var config = [
      "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
      "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-c",
      "core.attributesFile=/dev/null",
    ]
    let filters = try await run(
      config + [
        "config", "--null", "--name-only", "--get-regexp",
        "^filter\\..*\\.(clean|smudge|process|required)$",
      ], workspace: workspace, allowedExit: [0, 1])
    for raw in filters.split(separator: 0) {
      guard let key = String(data: Data(raw), encoding: .utf8), key.hasPrefix("filter."),
        !key.contains("\n"), key.utf8.count < 4_096
      else {
        throw WorkspacePatchError.reviewIncomplete
      }
      config += ["-c", key + (key.hasSuffix(".required") ? "=false" : "=")]
    }
    let rootResult = try await run(
      config + ["rev-parse", "--show-toplevel"], workspace: workspace, allowedExit: [0, 128])
    let root = String(decoding: rootResult, as: UTF8.self).trimmingCharacters(in: .newlines)
    // Git errors are combined with stdout, so only an exact absolute workspace root is accepted.
    guard root.hasPrefix("/"),
      URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        == workspace.standardizedFileURL.resolvingSymlinksInPath()
    else {
      return GitWorkspaceSnapshot(
        repository: "", head: "", status: Data(), stagedDiff: "", unstagedDiff: "", untracked: [:])
    }
    let head = try await run(
      config + ["rev-parse", "--verify", "HEAD"], workspace: workspace, allowedExit: [0, 128])
    let status = try await run(
      config + [
        "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all",
      ], workspace: workspace)
    let diff = [
      "diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--no-color",
      "--no-renames",
    ]
    let staged = try await run(config + diff + ["--cached", "--"], workspace: workspace)
    let unstaged = try await run(config + diff + ["--"], workspace: workspace)
    var untracked: [String: String] = [:]
    var bytes = 0
    var skipRename = false
    for entry in status.split(separator: 0) {
      if skipRename {
        skipRename = false
        continue
      }
      guard entry.count >= 4, entry[entry.startIndex + 2] == 32,
        let path = String(data: Data(entry.dropFirst(3)), encoding: .utf8)
      else { throw WorkspacePatchError.reviewIncomplete }
      let flags = String(decoding: entry.prefix(2), as: UTF8.self)
      skipRename = flags.contains("R") || flags.contains("C")
      if flags == "??" {
        guard untracked.count < 512 else { throw WorkspacePatchError.capacity }
        do {
          let file = try await fileSystem.readTextFile(at: path, relativeTo: workspace)
          bytes += file.byteCount
          guard bytes <= 16 * 1_024 * 1_024 else { throw WorkspacePatchError.capacity }
          untracked[path] = file.revision
        } catch let error as WorkspacePatchError { throw error } catch {
          untracked[path] = "unavailable (binary, linked, too large, or unreadable)"
        }
      }
    }
    // Reject a capture that crossed an observable HEAD/index/worktree movement. Git reads are
    // individually bounded; this second pass never writes an index or invokes configured helpers.
    guard
      try await run(
        config + [
          "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all",
        ], workspace: workspace) == status,
      try await run(
        config + ["rev-parse", "--verify", "HEAD"], workspace: workspace, allowedExit: [0, 128])
        == head,
      try await run(config + diff + ["--cached", "--"], workspace: workspace) == staged,
      try await run(config + diff + ["--"], workspace: workspace) == unstaged
    else { throw WorkspacePatchError.reviewIncomplete }
    for (path, revision) in untracked where WorkspaceRevision.isValid(revision) {
      guard try await fileSystem.readTextFile(at: path, relativeTo: workspace).revision == revision
      else { throw WorkspacePatchError.reviewIncomplete }
    }
    return GitWorkspaceSnapshot(
      repository: root, head: String(decoding: head, as: UTF8.self), status: status,
      stagedDiff: String(decoding: staged, as: UTF8.self),
      unstagedDiff: String(decoding: unstaged, as: UTF8.self), untracked: untracked)
  }

  private func run(_ arguments: [String], workspace: URL, allowedExit: Set<Int32> = [0])
    async throws -> Data
  {
    let result = try await executor.execute(
      ProcessExecutionRequest(
        executable: URL(fileURLWithPath: "/usr/bin/git"),
        arguments: arguments, workingDirectory: workspace,
        environment: [
          "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
          "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "LC_ALL": "C",
        ], timeoutSeconds: 15))
    guard case .exited(let code) = result.termination, allowedExit.contains(code),
      result.outputIsComplete
    else {
      throw WorkspacePatchError.reviewIncomplete
    }
    return result.output
  }
}
