import Testing

@testable import Hex

struct HexTests {
  @Test @MainActor
  func disconnectedWorkspaceExplainsWhyPromptCannotSend() {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())

    model.send()

    #expect(model.connectionState == .disconnected)
    #expect(model.errorMessage == "Connect to the gateway before sending a prompt.")
  }

  @Test @MainActor
  func previewRunPausesOnExactAuthorizationRequest() async throws {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())
    await model.connect()
    model.draft = "Inspect this project"
    model.send()

    for _ in 0..<20 where model.pendingAuthorization == nil {
      try await Task.sleep(nanoseconds: 50_000_000)
    }

    #expect(model.pendingAuthorization != nil)
    #expect(model.runState == .waitingForAuthorization)
  }
}
