import HexCore
import HexIPC

extension AgentWorkspaceModel {
  func captureArtifactInventory(_ result: ToolResult) throws {
    guard !result.artifacts.isEmpty,
      let index = conversations.firstIndex(where: { $0.id == selectedConversationID })
    else { return }
    var conversation = conversations[index]
    let previous = try conversation.availableArtifacts()
    for reference in result.artifacts {
      guard
        previous.contains(reference)
          || (reference.runID == currentRunID && reference.toolCallID == result.toolCallID)
      else {
        throw GatewayFailure(
          code: .malformedPayload,
          message: "The returned output does not belong to this tool or the saved conversation.")
      }
    }
    conversation.artifactInventory = previous + result.artifacts.filter { !previous.contains($0) }
    conversation.artifactInventory = try conversation.availableArtifacts()
    conversations[index] = conversation
  }
}
