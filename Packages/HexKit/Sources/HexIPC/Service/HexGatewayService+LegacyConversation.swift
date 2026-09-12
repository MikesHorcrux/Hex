import CryptoKit
import Foundation
import HexCore

extension HexGatewayService {
  /// Attach an old UI checkpoint to the same conversation without issuing another execution.
  /// The checkpoint comes from resident storage, never from a caller-supplied replacement request.
  func adoptLegacyConversation(_ id: UUID) async throws -> [AgentTaskRecord] {
    guard let taskStore, let conversationStore, let historyReader else {
      throw taskFailure("Conversation recovery is unavailable.")
    }
    let existing = try await taskStore.conversationTasks(id, before: nil, limit: 1)
    if !existing.isEmpty { return existing }
    guard let document = try await conversationStore.conversationStorage(.read(id)).documents.first,
      let object = try JSONSerialization.jsonObject(with: document.state) as? [String: Any],
      let pending = object["pendingRun"] as? [String: Any], let encoded = pending["request"]
    else { return [] }
    let source = try codec.decode(
      GatewayStartRunRequest.self,
      from: JSONSerialization.data(withJSONObject: encoded))
    guard let snapshot = try await historyReader.snapshot(for: source.runID) else {
      throw taskFailure(
        "The older run has no verifiable journal. Its original chat is retained; no work was repeated."
      )
    }
    if let first = pending["firstEventID"] {
      let expected = try JSONDecoder().decode(
        AgentEventID.self,
        from: JSONSerialization.data(withJSONObject: first, options: [.fragmentsAllowed]))
      guard expected == snapshot.firstEventID else {
        throw taskFailure("The older checkpoint does not match its journal.")
      }
    }
    let payload = try codec.encode(source)
    var record = AgentTaskRecord(
      id: source.runID.rawValue, title: document.title,
      request: payload, admissionHash: Data(SHA256.hash(data: payload)), now: document.createdAt)
    record.conversationID = id
    record.runID = source.runID
    record.attemptCount = 1
    record.attemptPending = true
    record.phase = .pausing
    record.explanation = "Checking saved progress before continuing"
    do { return [try await taskStore.saveTask(record).summary] } catch AgentTaskStorageError
      .revisionConflict
    {
      return try await taskStore.conversationTasks(id, before: nil, limit: 1)
    }
  }
}
