import Testing

@testable import Hex

struct HexTests {
  @Test
  func verificationLaunchArgumentIsExplicitAndDeterministic() {
    #expect(!HexApp.isVerificationOnlyLaunch(arguments: ["Hex"]))
    #expect(
      HexApp.isVerificationOnlyLaunch(arguments: ["Hex", "--hex-verify-no-connect"])
    )
    #expect(!HexApp.isOnboardingSuppressed(arguments: ["Hex"]))
    #expect(HexApp.isOnboardingSuppressed(arguments: ["Hex", "--hex-skip-onboarding"]))
    #expect(
      HexApp.isOnboardingSuppressed(arguments: ["Hex", "--hex-verify-no-connect"])
    )
  }

  @Test @MainActor
  func disconnectedWorkspaceExplainsWhyPromptCannotSend() {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient())

    model.send()

    #expect(model.connectionState == .disconnected)
    #expect(model.errorMessage == "Connect to the gateway before sending a prompt.")
  }

  @Test @MainActor
  func connectedWorkspaceRequiresAModelBeforeSending() async {
    let model = AgentWorkspaceModel(client: PreviewHexAgentClient(), modelID: "")
    await model.connect()
    model.draft = "Inspect this project"

    model.send()

    #expect(!model.canSend)
    #expect(
      model.errorMessage == "Configure a model in Resident setup before sending a prompt."
    )
    #expect(model.draft == "Inspect this project")
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
