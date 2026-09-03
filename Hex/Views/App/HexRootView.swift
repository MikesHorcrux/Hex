import Observation
import SwiftUI

struct HexRootView: View {
  @Bindable var workspace: AgentWorkspaceModel
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var inference: HexInferenceBackendSettingsModel
  @Bindable var personality: HexPersonalitySettingsModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  let suppressOnboarding: Bool
  let suppressAutomaticConnection: Bool

  @AppStorage("hex.onboarding.completed.v1") private var hasCompletedOnboarding = false
  @State private var hasBootstrapped = false

  var body: some View {
    Group {
      if suppressOnboarding || hasCompletedOnboarding {
        AgentWorkspaceView(model: workspace, connectOnAppear: false)
      } else {
        HexOnboardingView(
          inference: inference,
          residentSetup: residentSetup,
          personality: personality,
          startAtLogin: startAtLogin,
          accessibilityPermission: accessibilityPermission,
          onFinish: {
            hasCompletedOnboarding = true
          }
        )
      }
    }
    .task {
      guard !hasBootstrapped else { return }
      hasBootstrapped = true
      await residentSetup.load()
      await inference.load()
      workspace.modelID = residentSetup.modelID
      guard suppressOnboarding || hasCompletedOnboarding else { return }
      await connectIfNeeded()
    }
    .onChange(of: hasCompletedOnboarding) { _, isComplete in
      guard isComplete else { return }
      workspace.modelID = residentSetup.modelID
      Task {
        await connectIfNeeded()
      }
    }
    .onChange(of: residentSetup.saveGeneration) { _, _ in
      workspace.modelID = residentSetup.modelID
      guard !suppressAutomaticConnection else { return }
      Task {
        await startAtLogin.refresh()
      }
    }
    .onChange(of: inference.saveGeneration) { _, _ in
      let modelID = inference.effectiveModelID
      guard !modelID.isEmpty else { return }
      residentSetup.modelID = modelID
      workspace.modelID = modelID
    }
  }

  private func connectIfNeeded() async {
    guard !suppressAutomaticConnection else { return }
    await workspace.connect()
  }
}
