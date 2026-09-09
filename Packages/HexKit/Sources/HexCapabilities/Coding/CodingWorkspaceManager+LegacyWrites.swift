import CryptoKit
import Foundation
import HexCore

extension CodingWorkspaceManager {
  func executeLegacy(
    _ base: any HostTool, call: ToolCall, context: ToolExecutionContext,
    scope: ProcessSessionScope
  ) async throws -> ToolResult {
    try await acquire()
    defer { busy = false }
    let id = "\(context.runID.rawValue.uuidString):\(call.id.rawValue)"
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let digest = Data(SHA256.hash(data: try encoder.encode(call.arguments)))
    if let old = try await store().codingPatch(id) {
      guard old.digest == digest else { throw WorkspacePatchError.priorOutcomeUncertain }
      return ToolResult(
        toolCallID: call.id, status: old.state == "completed" ? .success : .failure,
        output: try ProcessSessionTool.value(old), requiresUserAttention: old.state != "completed")
    }
    try await baseline(scope)
    _ = try await store().codingGeneration(scope.taskID)
    let arguments = try ToolCallArguments(
      call.arguments,
      allowedNames: [
        "path", "content", "expected_revision", "old_text", "new_text", "expected_occurrences",
      ])
    let path = try arguments.requiredString(named: "path", maximumBytes: 4_096)
    let expected = try arguments.optionalString(named: "expected_revision", maximumBytes: 64)
    let old: WorkspaceTextFile?
    if let expected {
      old = try await fileSystem.readTextFile(at: path, relativeTo: workspace)
      guard old?.revision == expected else { throw WorkspaceFileSystemError.revisionConflict }
    } else {
      do {
        _ = try await fileSystem.readTextFile(at: path, relativeTo: workspace)
        throw WorkspaceFileSystemError.destinationExists
      } catch WorkspaceFileSystemError.notFound { old = nil }
    }
    let proposed: String
    if call.name == "workspace_write_text_file" {
      proposed = try arguments.requiredString(
        named: "content", maximumBytes: 1_048_576, allowsEmpty: true)
    } else {
      guard call.name == "workspace_replace_text", let old else {
        throw WorkspacePatchError.invalidPatch
      }
      proposed = try BoundedTextReplacement.build(
        source: old.content,
        replacing: arguments.requiredString(named: "old_text", maximumBytes: 1_048_576),
        with: arguments.requiredString(
          named: "new_text", maximumBytes: 1_048_576, allowsEmpty: true),
        expectedOccurrences: arguments.requiredInteger(
          named: "expected_occurrences", range: 1...10_000), maximumBytes: 1_048_576)
    }
    let metadata = ArtifactMetadata(
      runID: context.runID, toolCallID: call.id, mediaType: "text/plain")
    let before: ArtifactReference?
    if let old {
      before = try await artifacts.store(Data(old.content.utf8), metadata: metadata)
    } else {
      before = nil
    }
    let after = try await artifacts.store(Data(proposed.utf8), metadata: metadata)
    var receipt = WorkspacePatchReceipt(
      id: id, scope: scope, runID: context.runID, callID: call.id, digest: digest,
      files: [.init(path: path, before: before, after: after, expectedRevision: expected)])
    try await store().saveCodingPatch(receipt)
    do {
      let result = try await base.execute(call, in: context)
      receipt.state = result.status == .success ? "completed" : "partial"
      receipt.files[0].state = result.status == .success ? "applied" : "unknown"
      receipt.files[0].resultingRevision = result.status == .success ? after.sha256 : nil
      try await store().saveCodingPatch(receipt)
      var output = result.output
      if case .object(var object) = output {
        object["change_receipt_id"] = .string(id)
        output = .object(object)
      }
      return ToolResult(
        toolCallID: call.id, status: result.status, output: output,
        content: result.content, artifacts: result.artifacts,
        requiresUserAttention: result.requiresUserAttention || result.status != .success,
        executionOutcome: result.status == .success ? .completed : nil)
    } catch {
      receipt.state = "partial"
      receipt.files[0].state = "unknown"
      receipt.explanation =
        "The write did not return a receipt. Inspect the current revision before continuing."
      try await store().saveCodingPatch(receipt)
      throw error
    }
  }
}
