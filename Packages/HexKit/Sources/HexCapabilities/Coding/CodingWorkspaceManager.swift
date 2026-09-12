import CryptoKit
import Foundation
import HexCore

public actor CodingWorkspaceManager: CodingWorkspaceControlling {
  let fileSystem: WorkspaceFileSystem
  let artifacts: any ArtifactWriting
  let git: GitWorkspaceReader
  let workspace: URL
  var storage: (any CodingWorkspaceStorage)?
  var busy = false
  var processLeases: [UUID: UUID] = [:]

  public init(fileSystem: WorkspaceFileSystem, artifacts: any ArtifactWriting, workspace: URL)
    throws
  {
    self.fileSystem = fileSystem
    self.artifacts = artifacts
    self.workspace = workspace
    git = try GitWorkspaceReader(fileSystem: fileSystem)
  }

  public func attach(storage: any CodingWorkspaceStorage) throws {
    guard self.storage == nil else { throw WorkspacePatchError.unavailable }
    self.storage = storage
  }
  func store() throws -> any CodingWorkspaceStorage {
    guard let storage else { throw WorkspacePatchError.unavailable }
    return storage
  }
  func acquire() async throws {
    while busy { try await Task.sleep(for: .milliseconds(10)) }
    busy = true
  }
  func reserveProcess(_ scope: ProcessSessionScope, id: UUID) async throws {
    try await acquire()
    defer { busy = false }
    guard processLeases.values.allSatisfy({ $0 == scope.conversationID }) else {
      throw WorkspacePatchError.unavailable
    }
    processLeases[id] = scope.conversationID
  }
  func releaseProcess(_ id: UUID) { processLeases.removeValue(forKey: id) }
  func restoreLease(_ record: ProcessSessionRecord) {
    processLeases[record.id] = record.scope.conversationID
  }

  func baseline(_ scope: ProcessSessionScope) async throws {
    guard processLeases.values.allSatisfy({ $0 == scope.conversationID }) else {
      throw WorkspacePatchError.unavailable
    }
    guard scope.workspace.standardizedFileURL == workspace.standardizedFileURL else {
      throw WorkspacePatchError.unavailable
    }
    if try await store().codingBaseline(scope.taskID) == nil {
      try await store().saveCodingBaseline(git.snapshot(workspace: workspace), taskID: scope.taskID)
    }
  }
  func prepare(_ scope: ProcessSessionScope) async throws -> Int64 {
    try await acquire()
    defer { busy = false }
    try await baseline(scope)
    return try await store().codingGeneration(scope.taskID)
  }
  public func review(taskID: UUID, before: String? = nil, limit: Int = 10) async throws
    -> WorkspaceChangesReview
  {
    try await acquire()
    defer { busy = false }
    let baseline = try await store().codingBaseline(taskID)
    let current = try await git.snapshot(workspace: workspace)
    guard (1...10).contains(limit) else { throw WorkspacePatchError.invalidPatch }
    let all = try await store().codingPatches(taskID).reversed()
    let ordered = Array(all)
    let start: Int
    if let before {
      guard let index = ordered.firstIndex(where: { $0.id == before }) else {
        throw WorkspacePatchError.invalidPatch
      }
      start = index + 1
    } else {
      start = 0
    }
    let page = Array(ordered.dropFirst(start).prefix(limit))
    return WorkspaceChangesReview(
      taskID: taskID, baseline: baseline?.boundedPreview, current: current.boundedPreview,
      patches: page,
      explanation:
        "The baseline shows changes already present before this task's first coding action. Patch receipts identify typed Hex edits. Other observed changes have unknown authorship. Git previews are bounded; a truncated preview is not a complete review. Staged changes are preserved.",
      nextPatchID: start + page.count < ordered.count ? page.last?.id : nil,
      totalPatchCount: ordered.count)
  }

  func apply(
    text: String, revisions: [String: String], scope: ProcessSessionScope,
    context: ToolExecutionContext, call: ToolCall
  ) async throws -> WorkspacePatchReceipt {
    try await acquire()
    defer { busy = false }
    let id = "\(context.runID.rawValue.uuidString):\(call.id.rawValue)"
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let digest = Data(SHA256.hash(data: try encoder.encode(call.arguments)))
    if let prior = try await store().codingPatch(id) {
      guard prior.digest == digest else { throw WorkspacePatchError.priorOutcomeUncertain }
      return prior
    }
    try await baseline(scope)
    _ = try await store().codingGeneration(scope.taskID)
    let patch = try UnifiedPatch(text)
    guard Set(revisions.keys) == Set(patch.files.filter { !$0.creates }.map(\.path)) else {
      throw WorkspacePatchError.invalidPatch
    }
    var contents: [String] = []
    var files: [WorkspacePatchFileReceipt] = []
    let metadata = ArtifactMetadata(
      runID: context.runID, toolCallID: call.id, mediaType: "text/plain")
    // Complete preflight and preserve all proposed images before the first file is published.
    for file in patch.files {
      let old: WorkspaceTextFile?
      if file.creates {
        do {
          _ = try await fileSystem.readTextFile(at: file.path, relativeTo: workspace)
          throw WorkspaceFileSystemError.destinationExists
        } catch WorkspaceFileSystemError.notFound { old = nil }
      } else {
        old = try await fileSystem.readTextFile(at: file.path, relativeTo: workspace)
        guard old?.revision == revisions[file.path] else {
          throw WorkspaceFileSystemError.revisionConflict
        }
      }
      let proposed = try patch.applying(file, to: old?.content ?? "")
      contents.append(proposed)
      let before: ArtifactReference?
      if let old {
        before = try await artifacts.store(Data(old.content.utf8), metadata: metadata)
      } else {
        before = nil
      }
      let after =
        file.deletes ? nil : try await artifacts.store(Data(proposed.utf8), metadata: metadata)
      files.append(
        .init(path: file.path, before: before, after: after, expectedRevision: old?.revision))
    }
    var receipt = WorkspacePatchReceipt(
      id: id, scope: scope, runID: context.runID, callID: call.id, digest: digest, files: files)
    try await store().saveCodingPatch(receipt)
    for index in patch.files.indices {
      do {
        try Task.checkCancellation()
        let file = patch.files[index]
        if file.deletes, let revision = revisions[file.path] {
          let deletion = try await fileSystem.deleteTextFile(
            at: file.path,
            expectedRevision: revision, relativeTo: workspace)
          receipt.files[index].tombstone = deletion.tombstone
          guard deletion.confirmed else { throw WorkspaceFileSystemError.outcomeUncertain }
        } else {
          let result = try await fileSystem.writeTextFile(
            contents[index], at: file.path,
            expectedRevision: revisions[file.path], relativeTo: workspace)
          receipt.files[index].resultingRevision = result.revision
        }
        receipt.files[index].state = "applied"
        try await store().saveCodingPatch(receipt)
      } catch {
        receipt.state = "partial"
        receipt.files[index].state =
          error as? WorkspaceFileSystemError == .outcomeUncertain ? "unknown" : "failed"
        receipt.explanation =
          "Stopped at \(patch.files[index].path): \(error). Applied files were retained; pending files were not attempted. Inspect before continuing."
        try await store().saveCodingPatch(receipt)
        return receipt
      }
    }
    receipt.state = "completed"
    try await store().saveCodingPatch(receipt)
    return receipt
  }
}
