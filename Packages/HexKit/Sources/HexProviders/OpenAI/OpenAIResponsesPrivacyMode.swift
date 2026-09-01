/// Controls how a Responses API conversation is continued.
public enum OpenAIResponsesPrivacyMode: String, Codable, CaseIterable, Sendable {
  /// OpenAI stores response state and continuation sends `previous_response_id` plus only new items.
  case serverManagedContinuation = "server_managed_continuation"

  /// Requests use `store: false`; opaque response items needed for the next tool continuation are
  /// held only in bounded process memory. Continuation fails closed after eviction or process exit.
  case localEphemeralReplay = "local_ephemeral_replay"
}
