import HexCore

/// Encoded wholesale as the user message: neither old role names nor generated checkpoints can
/// escape this quoted-data envelope into trusted inference instructions.
struct AgentContextSummaryPayload: Encodable, Sendable {
  let previousSummary: String?
  let exchanges: [[Message]]
}
