import HexCore

extension AgentWorkspaceModel {
  /// Announcing a call is native tool evidence, but not proof of execution. Only explicit host
  /// receipts can rule out effects; missing results and old unspecified outcomes remain uncertain.
  var currentRunMayHaveToolEffects: Bool {
    guard currentRunHasToolEvidence else { return false }
    guard let conversation = conversations.first(where: { $0.id == selectedConversationID }),
      let exchange = conversation.history?.exchanges.first(where: { $0.runID == currentRunID })
    else { return true }
    var announced = Set<ToolCallID>()
    var notExecuted = Set<ToolCallID>()
    for part in exchange.messages.flatMap(\.content) {
      switch part {
      case .toolCall(let call): announced.insert(call.id)
      case .toolResult(let result):
        guard result.notExecutedReason != nil, result.hasValidNonExecutionMetadata else {
          return true
        }
        notExecuted.insert(result.toolCallID)
      case .text, .image: break
      }
    }
    return announced.isEmpty || announced != notExecuted
  }
}
