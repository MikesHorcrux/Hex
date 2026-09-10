import HexCore

/// Keeps media out of quoted JSON while preserving its original bytes as ordered image inputs.
/// Message and tool-call identifiers retain the relationship between each reference and its receipt.
struct AgentContextSummaryMediaProjection: Sendable {
  let currentTask: Message?
  let exchanges: [[Message]]
  let images: [ImageContent]

  init(currentTask: Message?, exchanges: [[Message]]) {
    var images: [ImageContent] = []

    func reference(_ image: ImageContent) -> String {
      images.append(image)
      return "Image attachment \(images.count) follows the JSON as original image input."
    }

    func project(_ message: Message) -> Message {
      Message(
        id: message.id, role: message.role,
        content: message.content.map { content in
          switch content {
          case .image(let image): return .text(reference(image))
          case .toolResult(let result):
            return .toolResult(
              ToolResult(
                toolCallID: result.toolCallID, status: result.status, output: result.output,
                content: result.content.map { part in
                  if case .image(let image) = part { return .text(reference(image)) }
                  return part
                }, artifacts: result.artifacts, requiresUserAttention: result.requiresUserAttention,
                notExecutedReason: result.notExecutedReason,
                executionOutcome: result.executionOutcome))
          case .text, .toolCall: return content
          }
        })
    }

    self.currentTask = currentTask.map(project)
    self.exchanges = exchanges.map { $0.map(project) }
    self.images = images
  }
}
