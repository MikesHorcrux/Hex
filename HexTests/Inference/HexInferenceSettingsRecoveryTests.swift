import Foundation
import HexCore
import HexProviders
import Testing

@testable import Hex

@Suite("Inference settings recovery")
struct HexInferenceSettingsRecoveryTests {
  @Test(arguments: SavePause.allCases) @MainActor
  func cancellationAfterNonCooperativeAwaitNeverPublishesSuccess(pause: SavePause) async throws {
    let gate = Gate()
    let store = Store(
      settings: try HexInferenceBackendSettings(), saveGate: pause == .settingsWrite ? gate : nil
    )
    let secrets = Secrets(existsGate: pause == .secretLookup ? gate : nil)
    let reloader = Reloader(gate: pause == .residentReload ? gate : nil)
    reloader.shouldFail = false
    let model = HexInferenceBackendSettingsModel(
      settingsStore: store, secretStore: secrets, configurationReloader: reloader
    )
    await model.load()
    model.openAIAPIKey = "test-new-key"
    let task = Task { await model.saveAndWait() }
    await gate.waitUntilStarted()

    model.cancelSave()
    await gate.release()

    #expect(!(await task.value))
    #expect(!model.isSaving)
    #expect(model.saveGeneration == 0)
    #expect(reloader.reloadCount == (pause == .residentReload ? 1 : 0))
  }

  @Test @MainActor
  func failedSettingsWriteReportsTheCredentialThatWasAlreadySaved() async throws {
    let initial = try HexInferenceBackendSettings()
    let store = Store(settings: initial, failsSave: true)
    let secrets = Secrets()
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: secrets)
    await model.load()
    model.openAIAPIKey = "test-new-key"

    #expect(!(await model.saveAndWait()))
    #expect(await secrets.saveCount == 1)
    #expect(await store.settings == initial)
    #expect(model.errorMessage?.contains("API key was saved") == true)
    #expect(model.saveGeneration == 0)
  }

  @Test @MainActor
  func cancellingAfterCredentialWriteReportsPartialSetupWithoutRollback() async throws {
    let gate = Gate()
    let store = Store(settings: try HexInferenceBackendSettings())
    let secrets = Secrets(saveGate: gate)
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: secrets)
    await model.load()
    model.openAIAPIKey = "test-new-key"
    let task = Task { await model.saveAndWait() }
    await gate.waitUntilStarted()
    model.cancelSave()
    await gate.release()

    #expect(!(await task.value))
    #expect(await secrets.saveCount == 1)
    #expect(await secrets.deleteCount == 0)
    #expect(await store.saveCount == 0)
    #expect(model.statusMessage?.contains("API key was saved") == true)
    #expect(model.statusMessage?.contains("unchanged") != true)
  }

  @Test @MainActor
  func editingTheFormAfterLoadFailureDoesNotHideRetry() async throws {
    let store = Store(settings: try HexInferenceBackendSettings(), failFirstLoad: true)
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: Secrets())
    await model.load()
    model.setupChoice = .onThisMac
    #expect(model.errorMessage == nil)
    #expect(model.needsLoadRetry)
    #expect(!model.canSave)
    await model.load()
    #expect(!model.needsLoadRetry)
  }

  @Test @MainActor
  func cancellationDuringReadinessDoesNotDisconnectOrRestartTheResident() async {
    let gate = Gate()
    let controller = LifecycleController()
    let resetter = ConnectionResetter()
    let lifecycle = HexStartAtLoginModel(
      controller: controller, readinessChecker: SuspendedReadiness(gate: gate),
      connectionResetter: resetter
    )
    let task = Task {
      do {
        try await lifecycle.reloadAfterConfigurationChange()
        return true
      } catch {
        return false
      }
    }
    await gate.waitUntilStarted()
    task.cancel()
    await gate.release()

    #expect(!(await task.value))
    #expect(await resetter.resetCount == 0)
    #expect(await controller.mutationCount == 0)
    #expect(!lifecycle.isUpdating)
  }

  @Test @MainActor
  func savePublishesPersistedSnapshotInsteadOfMutableDraftAndSurvivesReload() async throws {
    let store = Store(settings: try HexInferenceBackendSettings())
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: Secrets())
    await model.load()
    model.openAIModelID = "saved-a"
    model.save()
    model.openAIModelID = "unsaved-b"
    #expect(await model.saveAndWait())
    #expect(model.savedModelID == "saved-a")
    #expect(model.effectiveModelID == "unsaved-b")
    let reopened = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: Secrets())
    await reopened.load()
    #expect(reopened.savedModelID == "saved-a")
  }

  @Test @MainActor
  func failedApplyIsNotReportedAsSuccessfulSaveAndCanRetry() async throws {
    let store = Store(settings: try HexInferenceBackendSettings())
    let reloader = Reloader()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: store, secretStore: Secrets(), configurationReloader: reloader)
    await model.load()
    model.openAIModelID = "new-persisted-model"
    #expect(!(await model.saveAndWait()))
    #expect(model.savedModelID == "new-persisted-model")
    #expect(model.saveGeneration == 0)
    #expect(model.errorMessage?.contains("could not be applied") == true)
    #expect(!model.isSaving)
    reloader.shouldFail = false
    #expect(await model.saveAndWait())
    #expect(model.saveGeneration == 1)
  }

  @Test @MainActor
  func cancellingDownloadReturnsFalseAndLeavesPersistedBackendUntouched() async throws {
    let initial = try HexInferenceBackendSettings()
    let store = Store(settings: initial)
    let installer = SuspendedInstaller()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: store, secretStore: Secrets(), localModelInstaller: installer)
    await model.load()
    model.setupChoice = .onThisMac
    model.save()
    for _ in 0..<100 {
      if await installer.started { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await installer.started)
    model.cancelSave()
    #expect(!(await model.saveAndWait()))
    #expect(!model.isSaving)
    #expect(!model.isInstallingLocalModel)
    #expect(await store.settings == initial)
  }

  @Test @MainActor
  func failedLoadCanBeRetriedAndCannotSaveDefaultSettings() async throws {
    let settings = try HexInferenceBackendSettings(openAIModelID: "persisted-model")
    let store = Store(settings: settings, failFirstLoad: true)
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: Secrets())
    await model.load()
    #expect(model.errorMessage != nil)
    #expect(!model.canSave)
    model.openAIAuthenticationMethod = .apiKey
    model.save()
    for _ in 0..<20 { await Task.yield() }
    #expect(await store.saveCount == 0)
    await model.load()
    #expect(model.openAIModelID == "persisted-model")
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func unavailableInactiveLocalModelDoesNotBlockCloudSave() async throws {
    let local = try HexMLXBackendSettings(
      modelID: "old-local", displayName: "Old local",
      directory: URL(fileURLWithPath: "/nonexistent-hex-test-model-\(UUID().uuidString)"))
    let store = Store(settings: try HexInferenceBackendSettings(mlx: local))
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: Secrets())
    await model.load()
    model.openAIModelID = "new-cloud"
    // An inactive draft is not part of this save and must not prevent cloud recovery.
    model.mlxMaximumOutputTokens = "invalid inactive draft"
    model.save()
    for _ in 0..<100 {
      if model.saveGeneration == 1 || model.errorMessage != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.errorMessage == nil)
    #expect(await store.settings?.openAI.modelID == "new-cloud")
    #expect(await store.settings?.mlx == local)
  }

  @Test @MainActor
  func changingInstalledLocalIdentityInvalidatesOldArtifactSelection() async throws {
    let local = try HexMLXBackendSettings(
      modelID: "local-a", displayName: "Local A",
      directory: URL(fileURLWithPath: "/tmp/hex-model-identity-fixture"))
    let store = Store(
      settings: try HexInferenceBackendSettings(selectedBackend: .mlxLocal, mlx: local))
    let model = HexInferenceBackendSettingsModel(settingsStore: store, secretStore: Secrets())
    await model.load()
    model.mlxModelID = "local-b"
    #expect(model.mlxDirectory == nil)
    #expect(model.needsLocalModelDownload)
  }

  private actor Store: HexInferenceBackendSettingsStore {
    var settings: HexInferenceBackendSettings?
    var saveCount = 0
    private var failFirstLoad: Bool
    private let saveGate: Gate?
    private let failsSave: Bool

    init(
      settings: HexInferenceBackendSettings?, failFirstLoad: Bool = false,
      saveGate: Gate? = nil, failsSave: Bool = false
    ) {
      self.settings = settings
      self.failFirstLoad = failFirstLoad
      self.saveGate = saveGate
      self.failsSave = failsSave
    }

    func load() throws -> HexInferenceBackendSettings? {
      if failFirstLoad {
        failFirstLoad = false
        throw Failure.unavailable
      }
      return settings
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {
      await saveGate?.suspend()
      if failsSave { throw Failure.unavailable }
      self.settings = settings
      saveCount += 1
    }
  }

  private actor Secrets: HexSecretStore {
    private let saveGate: Gate?
    private let existsGate: Gate?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(saveGate: Gate? = nil, existsGate: Gate? = nil) {
      self.saveGate = saveGate
      self.existsGate = existsGate
    }

    func secret(for key: HexSecretKey) throws -> String { throw Failure.unavailable }
    func exists(_ key: HexSecretKey) async -> Bool {
      if saveCount > 0 { await existsGate?.suspend() }
      return key == .openAIAPIKey
    }
    func save(_ secret: String, for key: HexSecretKey) async {
      saveCount += 1
      await saveGate?.suspend()
    }
    func delete(_ key: HexSecretKey) { deleteCount += 1 }
  }

  private enum Failure: Error { case unavailable }

  @MainActor
  private final class Reloader: HexResidentConfigurationReloading {
    var shouldFail = true
    private let gate: Gate?
    private(set) var reloadCount = 0

    init(gate: Gate? = nil) { self.gate = gate }

    func reloadAfterConfigurationChange() async throws {
      reloadCount += 1
      await gate?.suspend()
      if shouldFail { throw Failure.unavailable }
    }
  }

  enum SavePause: CaseIterable, Sendable {
    case settingsWrite
    case secretLookup
    case residentReload
  }

  private actor Gate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
      await withCheckedContinuation { continuation in
        self.continuation = continuation
        started = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
      }
    }

    func waitUntilStarted() async {
      if started { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }

  private actor LifecycleController: HexGatewayLifecycleControlling {
    private(set) var mutationCount = 0
    func status() async -> HexGatewayLifecycleStatus { .enabled }
    func register() async throws { mutationCount += 1 }
    func unregister() async throws { mutationCount += 1 }
  }

  private actor ConnectionResetter: HexResidentGatewayConnectionResetting {
    private(set) var resetCount = 0
    func resetResidentGatewayConnection() async { resetCount += 1 }
  }

  private struct SuspendedReadiness: HexGatewayActivationReadinessChecking {
    let gate: Gate
    func check() async -> HexGatewayActivationReadiness {
      await gate.suspend()
      return .ready
    }
  }

  private actor SuspendedInstaller: MLXLocalModelInstalling {
    private(set) var started = false
    func install(modelID: String, progress: @Sendable @escaping (Double) -> Void) async throws
      -> URL
    {
      started = true
      try await Task.sleep(for: .seconds(60))
      throw Failure.unavailable
    }
  }
}
