import HexCore

extension AgentWorkspaceModel {
  func append(_ message: Message) {
    guard pendingInitialMessageIDs.remove(message.id) == nil else {
      return
    }

    let text = messageText(message)
    guard !text.isEmpty else { return }

    switch message.role {
    case .user:
      guard !(transcript.last?.role == .user && transcript.last?.text == text) else { return }
      transcript.append(ConversationItem(role: .user, text: text))
    case .assistant:
      if let streamingAssistantItemID,
        let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
      {
        transcript[index].text = text
        transcript[index].isStreaming = false
        self.streamingAssistantItemID = nil
      } else {
        transcript.append(ConversationItem(role: .assistant, text: text))
      }
    case .tool:
      transcript.append(ConversationItem(role: .tool, text: text))
    case .system, .developer:
      transcript.append(ConversationItem(role: .event, text: text))
    }
    updateCurrentConversation()
    persistConversationArchive()
  }

  func appendAssistantDelta(_ text: String) {
    guard !text.isEmpty else { return }
    if let streamingAssistantItemID,
      let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
    {
      transcript[index].text.append(text)
      return
    }

    let item = ConversationItem(role: .assistant, text: text, isStreaming: true)
    streamingAssistantItemID = item.id
    transcript.append(item)
    updateCurrentConversation()
    persistConversationArchive()
  }

  func finishStreamingAssistant() {
    guard let streamingAssistantItemID,
      let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
    else {
      return
    }
    transcript[index].isStreaming = false
    self.streamingAssistantItemID = nil
    updateCurrentConversation()
    persistConversationArchive()
  }

  func appendEvent(_ text: String) {
    transcript.append(ConversationItem(role: .event, text: text))
    updateCurrentConversation()
    persistConversationArchive()
  }

  func appendTool(_ text: String) {
    transcript.append(ConversationItem(role: .tool, text: text))
    updateCurrentConversation()
    persistConversationArchive()
  }

  func toolResultText(_ result: ToolResult) -> String {
    let status = result.status == .success ? "Succeeded" : "Failed"
    let output = HexJSONValueFormatter.string(from: result.output)
    return "\(status) · \(output)"
  }

  func stopReasonLabel(_ reason: InferenceStopReason) -> String {
    switch reason {
    case .stop:
      "stop"
    case .toolCalls:
      "tool calls"
    case .length:
      "length limit"
    case .contentFilter:
      "content filter"
    case .other(let value):
      value
    }
  }

  private func messageText(_ message: Message) -> String {
    message.content.compactMap { content in
      switch content {
      case .text(let text):
        text
      case .toolCall(let call):
        "Tool call · \(call.name)"
      case .toolResult(let result):
        toolResultText(result)
      case .image:
        "[Image]"
      }
    }
    .joined(separator: "\n")
  }

}
