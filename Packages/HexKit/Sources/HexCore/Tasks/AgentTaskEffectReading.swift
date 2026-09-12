import Foundation

/// A previous dispatch in this durable task. A nil result is an unknown outcome, never permission
/// to repeat it. Reads are keyed by canonical operation arguments, independent of provider call IDs.
public protocol AgentTaskEffectReading: Sendable {
  func previousTaskEffect(runID: AgentRunID, fingerprint: Data) async throws -> AgentTaskEffect?
}
