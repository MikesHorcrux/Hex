import Foundation
import HexCore

extension AgentConversation {
  /// The catalog is derived from preserved native provenance plus known-outcome receipts. Summary
  /// prose and arbitrary display text never supply an artifact grant.
  nonisolated func availableArtifacts(before requestRunID: AgentRunID? = nil) throws
    -> [ArtifactReference]
  {
    let history = resolvedHistory()
    var exchanges = history.exchanges
    if let requestRunID {
      guard var index = exchanges.firstIndex(where: { $0.runID == requestRunID }) else {
        throw artifactError("The pending artifact inventory has no request exchange.")
      }
      while let parent = exchanges[index].retryOfRunID {
        guard index > 0, exchanges[index - 1].runID == parent else {
          throw artifactError("The pending artifact inventory has invalid retry ancestry.")
        }
        index -= 1
      }
      exchanges = Array(exchanges.prefix(index))
    }
    let durableRuns = (artifactSources ?? []).map(\.runID).filter { $0 != requestRunID }
    let allowedRuns = Set(exchanges.map(\.runID) + durableRuns)
    let allNative = history.exchanges.flatMap(\.messages).flatMap(\.content)
      .flatMap { content -> [ArtifactReference] in
        if case .toolResult(let result) = content { return result.artifacts }
        return []
      }
    let references = (artifactInventory ?? []) + allNative
    var known: [UUID: ArtifactReference] = [:]
    var ordered: [ArtifactReference] = []
    for reference in references {
      if let earlier = known[reference.id] {
        guard earlier == reference else {
          throw artifactError("A saved output ID has conflicting manifests.")
        }
        continue
      }
      // Durable receipts are bounded by the archive, not the smaller next-run request inventory.
      // Otherwise the first output over that request limit permanently blocks event replay.
      do { try ToolArtifactValidation.validate([reference]) } catch {
        throw artifactError("A saved output reference is invalid.")
      }
      known[reference.id] = reference
      ordered.append(reference)
    }
    // A valid source call remains in native history even when its result never reached the next
    // messageAppended event. This includes a cancelled process's committed partial capture.
    for reference in known.values {
      if artifactSources?.contains(where: {
        $0.runID == reference.runID && $0.toolCallID == reference.toolCallID
      }) == true {
        continue
      }
      guard let callID = reference.toolCallID,
        let owner = history.exchanges.first(where: { $0.runID == reference.runID }),
        owner.messages.flatMap(\.content).contains(where: { part in
          if case .toolCall(let call) = part { return call.id == callID }
          return false
        })
      else { throw artifactError("A saved output has no preserved source tool call.") }
    }
    guard Set(history.exchanges.map(\.runID)).count == history.exchanges.count else {
      throw artifactError("The saved output catalog contains duplicate source run identities.")
    }
    // Keep the append-only capture order used by artifact_list; UUID sorting changes the meaning
    // of the next page offset when the user sends a follow-up message.
    return ordered.filter { allowedRuns.contains($0.runID) }
  }

  private nonisolated func artifactError(_ message: String) -> AgentConversationStoreError {
    .invalidArchive(message)
  }
}
