import Testing

@testable import Hex

@Suite("Transcript presentation does not delay canonical state")
struct AgentWorkspacePresentationTests {
  @Test @MainActor
  func replacementRowWithSameCountIsShownImmediately() {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.transcript = [ConversationItem(role: .assistant, text: "Old", isStreaming: true)]
    model.transcript = [ConversationItem(role: .assistant, text: "New", isStreaming: true)]
    #expect(model.presentedTranscript == model.transcript)
    #expect(model.presentedTranscript.last?.text == "New")
    #expect(model.transcriptPresentationTask == nil)
  }

  @Test @MainActor
  func burstUpdatesCanonicalTextImmediatelyAndPublishesOneSnapshot() async {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.appendAssistantDelta("First")
    #expect(model.presentedTranscript == model.transcript)
    for _ in 0..<100 { model.appendAssistantDelta(" token") }
    #expect(model.transcript.last?.text == "First" + String(repeating: " token", count: 100))
    #expect(model.presentedTranscript.last?.text == "First")
    await model.transcriptPresentationTask?.value
    #expect(model.presentedTranscript == model.transcript)
    #expect(model.transcriptPresentationTask == nil)
  }

  @Test @MainActor
  func terminalAndConversationSwitchFlushWithoutWaitingForAPaintTimer() async {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    model.appendAssistantDelta("Partial")
    model.appendAssistantDelta(" tail")
    let staleTimer = model.transcriptPresentationTask
    model.finishStreamingAssistant()
    #expect(model.presentedTranscript == model.transcript)
    #expect(model.presentedTranscript.last?.text == "Partial tail")
    #expect(model.presentedTranscript.last?.isStreaming == false)
    model.transcript = []
    await staleTimer?.value
    #expect(model.presentedTranscript.isEmpty)
    #expect(model.transcriptPresentationTask == nil)
  }
}
