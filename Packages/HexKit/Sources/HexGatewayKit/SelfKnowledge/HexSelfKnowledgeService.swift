import Foundation
import HexCore

/// One actor owns active snapshots. A tool can only inspect the snapshot for its runtime run ID.
public actor HexSelfKnowledgeService {
  private let knowledge: HexSelfKnowledge
  private let provider: ProviderDescriptor
  private var snapshots: [AgentRunID: JSONValue] = [:]

  public init(knowledge: HexSelfKnowledge, provider: ProviderDescriptor) {
    self.knowledge = knowledge
    self.provider = provider
  }

  public func beginRun(
    runID: AgentRunID,
    modelID: ModelID,
    workingDirectory: URL?,
    options: InferenceOptions
  ) throws -> Message {
    try Task.checkCancellation()
    guard snapshots[runID] == nil else { throw HexSelfKnowledgeServiceError.duplicateRun }
    guard snapshots.count < 128 else { throw HexSelfKnowledgeServiceError.capacityExceeded }
    let snapshot = knowledge.snapshot(
      provider: provider, modelID: modelID, workingDirectory: workingDirectory, options: options
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded = try encoder.encode(snapshot)
    let text = HexSelfOperatingManual().summary + "\n" + String(decoding: encoded, as: UTF8.self)
    snapshots[runID] = snapshot
    return Message(role: .developer, content: [.text(text)])
  }

  public func snapshot(for runID: AgentRunID) throws -> JSONValue {
    try Task.checkCancellation()
    guard let snapshot = snapshots[runID] else {
      throw HexSelfKnowledgeServiceError.runUnavailable
    }
    return snapshot
  }

  public func endRun(_ runID: AgentRunID) {
    snapshots.removeValue(forKey: runID)
  }
}
