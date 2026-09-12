import Observation

/// Owns the wizard transition, not the settings stores or the resident lifecycle.
@MainActor
@Observable
final class HexOnboardingCoordinator {
  private(set) var step: HexOnboardingStep
  private(set) var isAdvancing = false

  init(step: HexOnboardingStep = .welcome) {
    self.step = step
  }

  func goBack() {
    guard !isAdvancing, let previous = step.previous else { return }
    step = previous
  }

  func advance(
    saveInference: @MainActor () async -> Bool,
    prepareWorkspace: @MainActor () -> Void,
    saveResident: @MainActor () async -> Bool,
    savePersonality: @MainActor () async -> Bool,
    finish: @MainActor () -> Void
  ) async {
    guard !isAdvancing, !Task.isCancelled else { return }
    isAdvancing = true
    defer { isAdvancing = false }

    switch step {
    case .welcome:
      step = .inference
    case .inference:
      if await saveInference(), !Task.isCancelled { step = .workspace }
    case .workspace:
      prepareWorkspace()
      step = .tools
    case .tools:
      if await saveResident(), !Task.isCancelled { step = .permissions }
    case .permissions:
      // Approval policy is edited after the tools save. It must be durable and applied too.
      if await saveResident(), !Task.isCancelled { step = .personality }
    case .personality:
      if await savePersonality(), !Task.isCancelled { step = .ready }
    case .ready:
      finish()
    }
  }
}
