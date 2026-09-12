import HexCore
import Observation
import SwiftUI

struct HexOnboardingView: View {
  @Bindable var inference: HexInferenceBackendSettingsModel
  @Bindable var residentSetup: HexResidentSetupModel
  @Bindable var personality: HexPersonalitySettingsModel
  @Bindable var startAtLogin: HexStartAtLoginModel
  @Bindable var accessibilityPermission: HexAccessibilityPermissionModel
  let onFinish: @MainActor () -> Void

  @State private var coordinator = HexOnboardingCoordinator()
  @State private var advanceTask: Task<Void, Never>?
  @AccessibilityFocusState private var isStepHeadingFocused: Bool

  private var step: HexOnboardingStep { coordinator.step }

  var body: some View {
    HStack(spacing: 0) {
      HexOnboardingStepRailView(currentStep: step)

      Rectangle()
        .fill(HexBrandPalette.hairline)
        .frame(width: 1)

      VStack(spacing: 0) {
        HStack(spacing: 14) {
          Image(systemName: stepSymbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(HexBrandPalette.accentInk)
            .frame(width: 40, height: 40)
            .background(HexBrandPalette.softCoral, in: Circle())
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 2) {
            Text(stepTitle)
              .font(.title2.weight(.semibold))
              .foregroundStyle(HexBrandPalette.ink)
              .accessibilityFocused($isStepHeadingFocused)
            Text(stepDetail)
              .font(.callout)
              .foregroundStyle(HexBrandPalette.mutedInk)
          }

          Spacer()

          Text("Step \(step.position) of \(HexOnboardingStep.allCases.count)")
            .font(.caption.weight(.medium))
            .foregroundStyle(HexBrandPalette.mutedInk)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)

        ProgressView(
          value: Double(step.position),
          total: Double(HexOnboardingStep.allCases.count)
        )
        .progressViewStyle(.linear)
        .tint(HexBrandPalette.coral)
        .padding(.horizontal, 24)

        currentStep
          .scrollContentBackground(.hidden)
          .frame(maxWidth: .infinity, maxHeight: .infinity)

        Rectangle()
          .fill(HexBrandPalette.hairline)
          .frame(height: 1)

        HStack(spacing: 12) {
          Button("Back") {
            coordinator.goBack()
          }
          .buttonStyle(.hexSecondaryAction)
          .disabled(step.previous == nil || isBusy)

          Spacer()

          if step == .personality {
            Text("Optional — you can finish this later in Settings.")
              .font(.caption)
              .foregroundStyle(HexBrandPalette.mutedInk)
          }

          if isBusy {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(busyAccessibilityLabel)
          }

          Button(continueTitle, action: continueSetup)
            .buttonStyle(.hexPrimaryAction)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue || isBusy)
            .accessibilityIdentifier("onboardingContinueButton")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(HexBrandPalette.surface.opacity(0.74))
      }
      .background(HexBrandPalette.canvas)
    }
    .tint(HexBrandPalette.coral)
    .frame(minWidth: 860, minHeight: 620)
    .onChange(of: step) { _, _ in
      isStepHeadingFocused = true
    }
    .onAppear {
      isStepHeadingFocused = true
    }
    .onDisappear {
      advanceTask?.cancel()
      advanceTask = nil
    }
  }

  private var stepTitle: String {
    switch step {
    case .welcome:
      "Meet Hex"
    case .inference:
      "Choose the AI model"
    case .workspace:
      "Choose a workspace"
    case .tools:
      "Choose what Hex can do"
    case .permissions:
      "Allow Mac access"
    case .personality:
      "Make Hex yours"
    case .ready:
      "Ready when you are"
    }
  }

  private var stepDetail: String {
    switch step {
    case .welcome:
      "A local-first agent that can think, build, and act across your Mac."
    case .inference:
      "Hex runs the agent; you choose where its answers come from."
    case .workspace:
      "Pick the folder where Hex may read, search, edit, and run commands."
    case .tools:
      "Turn on browser, screen, or Xcode control. Missing components install automatically."
    case .permissions:
      "See exactly what is ready, what macOS still needs, and what to do next."
    case .personality:
      "Give Hex a name, voice, and boundaries — or leave this for later."
    case .ready:
      "Review the essentials, then start your first conversation."
    }
  }

  private var stepSymbol: String {
    switch step {
    case .welcome:
      "sparkles"
    case .inference:
      "cpu"
    case .workspace:
      "folder"
    case .tools:
      "wrench.and.screwdriver"
    case .permissions:
      "hand.raised"
    case .personality:
      "person.crop.circle"
    case .ready:
      "checkmark.seal"
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
      inference.needsLocalModelDownload ? "Download & Continue" : "Save & Continue"
    case .tools, .permissions:
      residentSetup.isInstallingManagedTool ? "Setting Up Tools…" : "Save & Continue"
    case .workspace:
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
      residentSetup.canSave && startAtLogin.status == .enabled
        && accessibilityPermission.hasVerifiedGateway
    case .personality:
      !personality.profile.hasDraftContent || personality.profile.canSave
    case .welcome, .ready:
      true
    }
  }

  private var isBusy: Bool {
    coordinator.isAdvancing
      || inference.isSaving || residentSetup.isSaving
      || residentSetup.isInstallingManagedTool || personality.profile.isSaving
  }

  private var busyAccessibilityLabel: String {
    residentSetup.isInstallingManagedTool ? "Setting up tools" : "Saving setup"
  }

  private func continueSetup() {
    guard advanceTask == nil else { return }
    advanceTask = Task {
      defer { advanceTask = nil }
      await coordinator.advance(
        saveInference: {
          guard await inference.saveAndWait(), let savedModelID = inference.savedModelID else {
            return false
          }
          residentSetup.modelID = savedModelID
          return true
        },
        prepareWorkspace: {
          if let savedModelID = inference.savedModelID {
            residentSetup.modelID = savedModelID
          }
        },
        saveResident: {
          guard await residentSetup.saveAndWait() else { return false }
          await startAtLogin.refresh()
          return true
        },
        savePersonality: {
          guard personality.profile.hasDraftContent else { return true }
          await personality.profile.save()
          return personality.profile.errorMessage == nil
        },
        finish: onFinish
      )
    }
  }
}
