import Foundation
import HexCore
import Testing

@testable import Hex

@Suite("Onboarding coordinator")
struct HexOnboardingCoordinatorTests {
  @Test @MainActor
  func failedSaveReleasesNavigationAndCanBeRetried() async {
    let coordinator = HexOnboardingCoordinator(step: .inference)
    let gate = SaveGate()
    let task = Task { await advance(coordinator, inference: { await gate.save() }) }
    await gate.waitUntilRequested()

    #expect(coordinator.isAdvancing)
    coordinator.goBack()
    #expect(coordinator.step == .inference)
    var duplicateSaveCalled = false
    await advance(
      coordinator,
      inference: {
        duplicateSaveCalled = true
        return true
      })
    #expect(!duplicateSaveCalled)

    gate.finish(false)
    await task.value
    #expect(!coordinator.isAdvancing)
    #expect(coordinator.step == .inference)

    await advance(coordinator)
    #expect(coordinator.step == .workspace)
    #expect(!coordinator.isAdvancing)
  }

  @Test @MainActor
  func failedResidentSaveStaysOnTheCurrentStepAndAllowsBack() async {
    for step in [HexOnboardingStep.tools, .permissions] {
      let coordinator = HexOnboardingCoordinator(step: step)
      await advance(coordinator, resident: { false })
      #expect(coordinator.step == step)
      #expect(!coordinator.isAdvancing)
      coordinator.goBack()
      #expect(coordinator.step == step.previous)
    }
  }

  @Test @MainActor
  func cancellationCannotAdvanceAfterANonCooperativeSaveCompletes() async {
    let coordinator = HexOnboardingCoordinator(step: .inference)
    let gate = SaveGate()
    let task = Task { await advance(coordinator, inference: { await gate.save() }) }
    await gate.waitUntilRequested()
    task.cancel()
    gate.finish(true)
    await task.value
    #expect(coordinator.step == .inference)
    #expect(!coordinator.isAdvancing)
  }

  @Test @MainActor
  func permissionsStepPersistsTheNewApprovalChoiceBeforeAdvancing() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HexOnboarding-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let settings = try HexResidentRuntimeSettings(modelID: "test-model", workspaceRoot: workspace)
    let store = SettingsStore(settings: settings)
    let model = HexResidentSetupModel(settingsStore: store, secretStore: EmptySecretStore())
    await model.load()
    #expect(await model.saveAndWait())
    model.authorizationMode = .fullAccess
    let coordinator = HexOnboardingCoordinator(step: .permissions)

    await advance(coordinator, resident: { await model.saveAndWait() })

    #expect(coordinator.step == .personality)
    #expect(await store.savedSettings.authorizationMode == .fullAccess)
    let restored = HexResidentSetupModel(settingsStore: store, secretStore: EmptySecretStore())
    await restored.load()
    #expect(restored.authorizationMode == .fullAccess)
  }

  @MainActor
  private func advance(
    _ coordinator: HexOnboardingCoordinator,
    inference: @MainActor () async -> Bool = { true },
    resident: @MainActor () async -> Bool = { true }
  ) async {
    await coordinator.advance(
      saveInference: inference,
      prepareWorkspace: {},
      saveResident: resident,
      savePersonality: { true },
      finish: {}
    )
  }

  @MainActor
  private final class SaveGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func save() async -> Bool {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
      }
    }

    func waitUntilRequested() async {
      if continuation != nil { return }
      await withCheckedContinuation { requestWaiters.append($0) }
    }

    func finish(_ succeeded: Bool) {
      continuation?.resume(returning: succeeded)
      continuation = nil
    }
  }

  private actor SettingsStore: HexResidentRuntimeSettingsStore {
    private(set) var savedSettings: HexResidentRuntimeSettings

    init(settings: HexResidentRuntimeSettings) { savedSettings = settings }
    func load() async throws -> HexResidentRuntimeSettings? { savedSettings }
    func save(_ settings: HexResidentRuntimeSettings) async throws { savedSettings = settings }
  }

  private actor EmptySecretStore: HexSecretStore {
    enum StoreError: Error { case absent }
    func secret(for key: HexSecretKey) async throws -> String { throw StoreError.absent }
    func exists(_ key: HexSecretKey) async throws -> Bool { false }
    func save(_ secret: String, for key: HexSecretKey) async throws {}
    func delete(_ key: HexSecretKey) async throws {}
  }
}
