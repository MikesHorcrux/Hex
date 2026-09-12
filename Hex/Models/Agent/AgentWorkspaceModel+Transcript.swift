import HexCore

extension AgentWorkspaceModel {
  func append(_ message: Message) {
    guard !pendingInitialMessageIDs.contains(message.id) else {
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
      let results = message.content.compactMap { part -> ToolResult? in
        if case .toolResult(let result) = part { return result }
        return nil
      }
      // A toolFinished event is followed by its native message. Preserve both journal facts, but
      // show one result row. The saved call ID also makes this work after a restart between them.
      if results.count == 1, let result = results.first,
        transcript.last?.toolCallID == result.toolCallID
      {
        return
      }
      transcript.append(
        ConversationItem(
          role: .tool, text: text, artifacts: results.flatMap(\.artifacts),
          toolCallID: results.count == 1 ? results.first?.toolCallID : nil))
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
      transcript[index].isStreaming = true
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

  /// A dropped stream is not a completed assistant message. Keep the row identity for same-run
  /// suffix replay, but stop its activity indicator while the connection is unavailable.
  func pauseStreamingAssistant() {
    if let streamingAssistantItemID,
      let index = transcript.firstIndex(where: { $0.id == streamingAssistantItemID })
    {
      transcript[index].isStreaming = false
    }
    updateCurrentConversation()
    persistConversationArchive()
  }

  func appendEvent(_ text: String) {
    transcript.append(ConversationItem(role: .event, text: text))
    updateCurrentConversation()
    persistConversationArchive()
  }

  func appendTool(
    _ text: String, artifacts: [ArtifactReference] = [], toolCallID: ToolCallID? = nil
  ) {
    transcript.append(
      ConversationItem(
        role: .tool, text: text, artifacts: artifacts, toolCallID: toolCallID))
    updateCurrentConversation()
    persistConversationArchive()
  }

  func toolResultText(_ result: ToolResult) -> String {
    AgentMessagePresentation.toolResultText(result)
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
    AgentMessagePresentation.text(message)
  }

}
