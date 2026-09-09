import CryptoKit
import Foundation
import HexCore

public struct WorkspacePatchTool: HostTool {
  public let definition = ToolDefinition(
    name: "workspace_apply_patch",
    description:
      "Apply a bounded exact unified diff to UTF-8 workspace files. Supply --- a/path, +++ b/path and @@ hunks; use /dev/null for create/delete. No fuzzy matching, rename, binary, mode or missing-newline patches. Existing files require revisions from workspace_read_text_file. Complete preflight precedes per-file publication; inspect partial receipts before continuing. Deleted files are retained in a recovery tombstone.",
    inputSchema: HostToolSchema.object(
      properties: [
        "patch": HostToolSchema.string(
          "Exact unified diff, ending in newline. Maximum 32 files and 512 KiB.",
          maximumLength: 524_288),
        "expected_revisions": .object([
          "type": .string("object"),
          "description": .string(
            "Map every updated/deleted relative path to its observed SHA-256 revision; omit created files."
          ),
          "additionalProperties": .object([
            "type": .string("string"), "minLength": .integer(64), "maxLength": .integer(64),
          ]),
        ]),
      ], required: ["patch", "expected_revisions"]))
  let manager: CodingWorkspaceManager
  let sessions: ProcessSessionManager
  private let calls = ToolAuthorizationLedger(maximumEntries: 8)
  private let key = SymmetricKey(size: .bits256)

  public init(manager: CodingWorkspaceManager, sessions: ProcessSessionManager) {
    self.manager = manager
    self.sessions = sessions
  }

  private func parse(_ call: ToolCall) throws -> (String, [String: String]) {
    guard call.name == definition.name else { throw WorkspacePatchError.invalidPatch }
    let args = try ToolCallArguments(call.arguments, allowedNames: ["patch", "expected_revisions"])
    let text = try args.requiredString(named: "patch", maximumBytes: 524_288)
    _ = try UnifiedPatch(text)
    guard case .object(let raw) = call.arguments["expected_revisions"], raw.count <= 32 else {
      throw WorkspacePatchError.invalidPatch
    }
    var revisions: [String: String] = [:]
    for (path, value) in raw {
      guard case .string(let revision) = value, WorkspaceRevision.isValid(revision) else {
        throw WorkspaceFileSystemError.invalidRevision
      }
      revisions[path] = revision
    }
    return (text, revisions)
  }
  public func authorizationRequest(for call: ToolCall, in context: ToolExecutionContext)
    async throws -> AuthorizationRequest
  {
    let text: String
    do {
      (text, _) = try parse(call)
    } catch {
      // Pure argument validation only: no workspace access, authorization, or ledger mutation.
      throw ToolCallValidationError(
        recovery:
          "Supply an exact unified diff ending in newline: --- a/path, +++ b/path, and @@ hunks. "
          + "Use /dev/null for creates/deletes. Each hunk's old/new counts must match its body; "
          + "prefix context lines with a space, removals with -, and additions with +. "
          + "Do not include *** Begin Patch or *** End Patch markers. "
          + "Use valid relative workspace paths and a SHA-256 expected_revisions entry for each "
          + "updated/deleted file from workspace_read_text_file. No files were changed.")
    }
    let scope = try await sessions.scope(context)
    let files = try UnifiedPatch(text).files
    for file in files {
      _ = try await manager.fileSystem.authorizationResource(
        path: file.path, workingDirectory: scope.workspace)
    }
    try await calls.record(call: call, runID: context.runID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let digest = HMAC<SHA256>.authenticationCode(
      for: try encoder.encode(call.arguments), using: key
    ).map { String(format: "%02x", $0) }.joined()
    return AuthorizationRequest(
      runID: context.runID, toolCallID: call.id, capability: .init(rawValue: "workspace.write"),
      operation: "apply_patch", resource: "patch:\(scope.workspace.path):\(digest)",
      details: [
        "files": .array(files.map { .string($0.path) }),
        "patch_bytes": .integer(Int64(text.utf8.count)),
        "patch_preview": .string(String(text.prefix(8_192))),
        "preview_truncated": .boolean(text.count > 8_192),
      ],
      explanation:
        "Apply this revision-checked patch. Each file is atomic; a partial operation preserves its completed edits and recovery images."
    )
  }
  public func execute(_ call: ToolCall, in context: ToolExecutionContext) async throws -> ToolResult
  {
    try await calls.take(call: call, runID: context.runID)
    let (text, revisions) = try parse(call)
    let receipt: WorkspacePatchReceipt
    do {
      receipt = try await manager.apply(
        text: text, revisions: revisions,
        scope: sessions.scope(context), context: context, call: call)
    } catch WorkspacePatchError.invalidPatch {
      return ToolResult(
        toolCallID: call.id, status: .failure,
        output: .object([
          "error": .string("invalid_patch"),
          "recovery": .string(
            "Read the current files and use exact context, consistent old/new hunk offsets, "
              + "and expected revisions for exactly the updated/deleted paths. No files were changed."
          ),
        ]))
    } catch {
      // Known preflight failures precede all publication. The manager returns partial receipts
      // after publication begins; cancellation, unknown outcomes and storage errors still throw.
      return try WorkspaceToolResult.failure(error, callID: call.id)
    }
    return ToolResult(
      toolCallID: call.id, status: receipt.state == "completed" ? .success : .failure,
      output: try ProcessSessionTool.value(receipt),
      requiresUserAttention: receipt.state != "completed",
      executionOutcome: receipt.state == "completed" ? .completed : nil)
  }
}
