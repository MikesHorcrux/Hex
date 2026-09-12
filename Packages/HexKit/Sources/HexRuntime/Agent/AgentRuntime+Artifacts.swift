import Foundation
import HexCore

extension AgentRuntime {
  /// Keep authority outside the lossy inference projection. Admission validates both sources before
  /// model discovery or journaling, and never recovers references by parsing a generated summary.
  func prepareArtifactInventory(for request: AgentRunRequest) throws {
    let original = request.contextMessages + request.initialMessages
    let references: [ArtifactReference]
    do {
      try ToolArtifactValidation.validate(request.availableArtifacts)
      references = try mergingArtifacts(
        request.availableArtifacts, with: artifactReferences(in: original))
    } catch {
      throw AgentRuntimeError.invalidRequest(
        "Preserved output references are invalid or exceed this run's supported inventory.")
    }
    let context = AgentArtifactContext.message(preservedCount: references.count)
    if let context, original.contains(where: { $0.id == context.id }) {
      throw AgentRuntimeError.invalidRequest(
        "The preserved-output context has a duplicate message ID.")
    }
    let projected = request.contextMessages + (context.map { [$0] } ?? []) + request.initialMessages
    let projectedBytes: Int
    let inventoryBytes: Int
    do {
      projectedBytes = try JSONEncoder().encode(projected).count
      inventoryBytes =
        request.availableArtifacts.isEmpty
        ? 0 : try JSONEncoder().encode(request.availableArtifacts).count
    } catch {
      throw AgentRuntimeError.invalidRequest("Preserved output references must be serializable.")
    }
    let (inputBytes, overflow) = projectedBytes.addingReportingOverflow(inventoryBytes)
    guard !overflow, inputBytes <= configuration.budget.maxInitialInputBytes else {
      throw AgentRuntimeError.budgetExceeded(
        "Initial input byte budget exceeded, including preserved output references.")
    }
    guard projectedBytes <= configuration.budget.maxConversationBytes else {
      throw AgentRuntimeError.budgetExceeded(
        "Conversation byte budget exceeded, including preserved-output discovery context.")
    }
    runArtifacts[request.runID] = references
    runArtifactContextMessages[request.runID] = context
  }

  func artifactReferences(in messages: [Message]) throws -> [ArtifactReference] {
    var references: [ArtifactReference] = []
    for message in messages {
      for content in message.content {
        if case .toolResult(let result) = content {
          for reference in result.artifacts where !references.contains(reference) {
            references.append(reference)
          }
        }
      }
    }
    try ToolArtifactValidation.validate(references)
    return references
  }

  func rememberArtifacts(_ references: [ArtifactReference], for runID: AgentRunID) throws {
    runArtifacts[runID] = try mergingArtifacts(runArtifacts[runID] ?? [], with: references)
  }

  private func mergingArtifacts(
    _ existing: [ArtifactReference], with incoming: [ArtifactReference]
  ) throws -> [ArtifactReference] {
    var available: [ArtifactReference] = []
    var seen: [UUID: ArtifactReference] = [:]
    for reference in existing + incoming {
      if let previous = seen[reference.id] {
        guard previous == reference else { throw ArtifactStoreError.invalidRequest }
      } else {
        seen[reference.id] = reference
        available.append(reference)
      }
    }
    try ToolArtifactValidation.validate(available)
    return available
  }

  /// Output is captured before applying inline budgets. The original status/call identity and
  /// complete structured result remain recoverable even when only a small preview fits in context.
  func persistLargeToolOutput(_ original: ToolResult, runID: AgentRunID) async throws -> ToolResult
  {
    try ToolArtifactValidation.validate(original.artifacts)
    let encoded: Data
    do { encoded = try JSONEncoder().encode(original) } catch {
      throw AgentRuntimeError.toolExecutionFailure("The executed tool result could not be encoded.")
    }
    let inlineLimit = min(32 * 1_024, configuration.budget.maxToolResultBytes)
    let images = original.content.filter {
      if case .image = $0 { return true }
      return false
    }
    // Ordinary image observations must remain visible to vision inference. Avoid spilling them
    // merely because their encoded image bytes exceed the text-preview threshold.
    let imageOnlySize = try JSONEncoder().encode(images).count
    let fitsTextPreview = encoded.count - imageOnlySize <= inlineLimit
    guard let artifactWriter else {
      // Inference's inline limit is not the durability limit. Keep a journal-sized known outcome
      // intact so the caller can persist it before enforcing the smaller continuation budget.
      guard try knownToolOutcomeFitsJournalEnvelope(original) else {
        try await stopForUnpreservedToolOutput(
          original, runID: runID,
          detail:
            "The tool returned output larger than Hex's journal can preserve, and no output store is available. Its full output was not saved. Inspect the action before deciding what to do next; Hex will not repeat it automatically."
        )
      }
      return original
    }
    guard encoded.count > inlineLimit,
      !(fitsTextPreview && encoded.count <= configuration.budget.maxToolResultBytes)
    else { return original }

    let metadata = ArtifactMetadata(
      runID: runID, toolCallID: original.toolCallID, mediaType: "application/json")
    let reference: ArtifactReference
    do {
      // Once the tool returns, cancellation must not erase its known output before journaling.
      reference = try await Task.detached {
        try await artifactWriter.store(encoded, metadata: metadata)
      }.value
    } catch {
      try await stopForUnpreservedToolOutput(
        original, runID: runID,
        detail:
          "The tool returned, but saving its full output failed. Its action must not be retried automatically."
      )
    }
    var previewBytes = min(8 * 1_024, max(0, inlineLimit / 4))
    let preview = String(decoding: encoded.prefix(previewBytes), as: UTF8.self)
    var fields: [String: JSONValue] = [
      "stored_tool_result": .boolean(true),
      "preview": .string(preview),
      "preview_truncated": .boolean(true),
      "original_bytes": .integer(Int64(encoded.count)),
      "message": .string(
        "Full structured output is saved. Use artifact_read or artifact_search with the artifact ID; offsets are bytes."
      ),
    ]
    // Preserve the small control receipt independently of the arbitrarily ordered JSON preview.
    // These values do not confer authority: each executor still validates its run-owned ledger.
    if case .object(let output) = original.output {
      for key in [
        "observation_id", "hex_observation_id", "snapshot", "hex_observed_pid",
        "hex_observed_window_id", "hex_process_start_identity_decimal",
        "hex_observation_expires_after_seconds", "hex_observation_actionable",
        "bundle_id", "process_id", "is_truncated", "recovery",
      ] {
        guard let value = output[key] else { continue }
        switch value {
        case .string(let text) where text.utf8.count <= 256: fields[key] = value
        case .integer, .boolean: fields[key] = value
        default: break
        }
      }
    }
    let references = [reference] + original.artifacts
    var bounded = ToolResult(
      toolCallID: original.toolCallID, status: original.status, output: .object(fields),
      content: images, artifacts: references, requiresUserAttention: original.requiresUserAttention,
      executionOutcome: original.executionOutcome)
    if try JSONEncoder().encode(bounded).count > configuration.budget.maxToolResultBytes,
      !images.isEmpty
    {
      fields["rich_content_stored_only"] = .boolean(true)
      fields["message"] = .string(
        "Full output, including rich content, is saved. Rich content exceeded this run's inline limit and is not visible as an image in this response."
      )
      bounded = ToolResult(
        toolCallID: original.toolCallID, status: original.status, output: .object(fields),
        artifacts: references, requiresUserAttention: original.requiresUserAttention,
        executionOutcome: original.executionOutcome)
    }
    while try JSONEncoder().encode(bounded).count > configuration.budget.maxToolResultBytes,
      previewBytes > 0
    {
      previewBytes /= 2
      fields["preview"] = .string(String(decoding: encoded.prefix(previewBytes), as: UTF8.self))
      bounded = ToolResult(
        toolCallID: original.toolCallID, status: original.status, output: .object(fields),
        content: bounded.content, artifacts: references,
        requiresUserAttention: original.requiresUserAttention,
        executionOutcome: original.executionOutcome)
    }
    if try JSONEncoder().encode(bounded).count > configuration.budget.maxToolResultBytes {
      bounded = ToolResult(
        toolCallID: original.toolCallID, status: original.status,
        output: .object(["stored_tool_result": .boolean(true)]), artifacts: references,
        requiresUserAttention: original.requiresUserAttention,
        executionOutcome: original.executionOutcome)
    }
    if try JSONEncoder().encode(bounded).count > configuration.budget.maxToolResultBytes {
      // A deliberately tiny context budget may not fit even the immutable reference. Preserve it
      // in the journal before stopping, instead of losing the link to a successfully saved result.
      _ = try await persistKnownToolReceipt(bounded, for: runID)
      try Task.checkCancellation()
      throw AgentRuntimeError.budgetExceeded(
        "The tool output was saved, but its reference exceeds this run's inline result budget.")
    }
    return bounded
  }

  private func knownToolOutcomeFitsJournalEnvelope(_ result: ToolResult) throws -> Bool {
    // Match AgentRuntime+Journal's exact AgentEvent JSON encoding and configured envelope, including
    // the larger native-message wrapper. A raw ToolResult byte count alone misses that boundary.
    let events: [AgentEvent] = [
      .toolFinished(result),
      .messageAppended(Message(role: .tool, content: [.toolResult(result)])),
    ]
    for event in events {
      if try JSONEncoder().encode(event).count > configuration.budget.maxJournalEventBytes {
        return false
      }
    }
    return true
  }

  private func stopForUnpreservedToolOutput(
    _ original: ToolResult, runID: AgentRunID, detail: String
  ) async throws -> Never {
    // This receipt is not truncated output and does not claim the full result was preserved. Keep
    // the known status, call and any already committed artifacts before stopping without a retry.
    let receipt = ToolResult(
      toolCallID: original.toolCallID, status: original.status,
      output: .object([
        "output_storage_failed": .boolean(true),
        "full_output_preserved": .boolean(false),
        "message": .string(detail),
      ]), artifacts: original.artifacts, requiresUserAttention: true)
    _ = try await persistKnownToolReceipt(receipt, for: runID)
    try Task.checkCancellation()
    throw AgentRuntimeError.toolExecutionFailure(detail)
  }
}
