import HexCore
import Observation
import SwiftUI

struct HexOnboardingView: View {
  @Bindable var inference: HexInferenceBackendSettingsModel
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var personality: HexPersonalitySettingsModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  let onFinish: () -> Void

  @State private var step = HexOnboardingStep.welcome
  @State private var isWaitingForInferenceSave = false
  @State private var isWaitingForResidentSave = false
  @State private var isWaitingForPersonalitySave = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "hexagon.fill")
          .foregroundStyle(.tint)
        Text("Set Up Hex")
          .font(.headline)
        Spacer()
        Text("\(step.position) of \(HexOnboardingStep.allCases.count) · \(step.title)")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)

      ProgressView(
        value: Double(step.position),
        total: Double(HexOnboardingStep.allCases.count)
      )
      .progressViewStyle(.linear)

      Divider()

      currentStep
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      HStack {
        Button("Back") {
          if let previous = step.previous {
            step = previous
          }
        }
        .disabled(step.previous == nil || isBusy)

        Spacer()

        if step == .personality {
          Text("Optional—you can finish this later in Settings.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button(continueTitle, action: continueSetup)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!canContinue || isBusy)
          .accessibilityIdentifier("onboardingContinueButton")
      }
      .padding(16)
      .background(.bar)
    }
    .frame(minWidth: 720, minHeight: 560)
    .onChange(of: inference.saveGeneration) { _, _ in
      guard isWaitingForInferenceSave else { return }
      isWaitingForInferenceSave = false
      residentSetup.modelID = inference.effectiveModelID
      step = .workspace
    }
    .onChange(of: residentSetup.saveGeneration) { _, _ in
      guard isWaitingForResidentSave else { return }
      isWaitingForResidentSave = false
      Task {
        await startAtLogin.refresh()
      }
      step = .permissions
    }
  }

  @ViewBuilder
  private var currentStep: some View {
    switch step {
    case .welcome:
      HexOnboardingWelcomeView()
    case .inference:
      HexOnboardingInferenceView(model: inference)
    case .workspace:
      HexOnboardingWorkspaceView(model: residentSetup)
    case .tools:
      HexOnboardingToolsView(model: residentSetup)
    case .permissions:
      HexOnboardingPermissionsView(
        model: residentSetup,
        startAtLogin: startAtLogin,
        accessibilityPermission: accessibilityPermission
      )
    case .personality:
      HexOnboardingPersonalityView(model: personality)
    case .ready:
      HexOnboardingReadyView(
        residentSetup: residentSetup,
        startAtLogin: startAtLogin
      )
    }
  }

  private var continueTitle: String {
    switch step {
    case .welcome:
      "Get Started"
    case .inference:
      "Save & Continue"
    case .tools:
      "Save & Continue"
    case .workspace, .permissions:
      "Continue"
    case .personality:
      personality.profile.hasDraftContent ? "Save & Continue" : "Skip for Now"
    case .ready:
      "Start Using Hex"
    }
  }

  private var canContinue: Bool {
    switch step {
    case .inference:
      inference.canSave && !inference.effectiveModelID.isEmpty
    case .workspace:
      residentSetup.hasValidCoreSettings
    case .tools:
      residentSetup.canSave
    case .permissions:
      startAtLogin.status == .enabled && accessibilityPermission.hasVerifiedGateway
    case .personality:
      !personality.profile.hasDraftContent || personality.profile.canSave
    case .welcome, .ready:
      true
    }
  }

  private var isBusy: Bool {
    isWaitingForInferenceSave || isWaitingForResidentSave || isWaitingForPersonalitySave
      || inference.isSaving || residentSetup.isSaving
      || personality.profile.isSaving
  }

  private func continueSetup() {
    switch step {
    case .welcome:
      step = .inference
    case .inference:
      isWaitingForInferenceSave = true
      inference.save()
      if !inference.isSaving {
        isWaitingForInferenceSave = false
      }
    case .workspace:
      residentSetup.modelID = inference.effectiveModelID
      step = .tools
    case .tools:
      isWaitingForResidentSave = true
      residentSetup.save()
      if !residentSetup.isSaving {
        isWaitingForResidentSave = false
      }
    case .permissions:
      step = .personality
    case .personality:
      guard personality.profile.hasDraftContent else {
        step = .ready
        return
      }
      isWaitingForPersonalitySave = true
      Task {
        await personality.profile.save()
        isWaitingForPersonalitySave = false
        if personality.profile.errorMessage == nil {
          step = .ready
        }
      }
    case .ready:
      onFinish()
    }
  }
}
