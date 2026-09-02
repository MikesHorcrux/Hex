import Foundation
import HexCore
import HexProviders
import Testing

@testable import Hex

@Suite("Inference backend settings model")
struct HexInferenceBackendSettingsModelTests {
  @Test @MainActor
  func codexStatusIsReadOnlyOnExplicitRefresh() async {
    let provider = TrackingStatusProvider()
    let model = HexInferenceBackendSettingsModel(
      settingsStore: EmptySettingsStore(),
      secretStore: EmptySecretStore(),
      makeCodexStatusProvider: { _ in provider }
    )

    await model.load()
    #expect(await provider.statusCallCount == 0)

    model.codexExecutableURL = URL(fileURLWithPath: "/Users/test/bin/codex")
    model.refreshCodexAccountStatus()
    await waitForStatusRead(provider)

    #expect(await provider.statusCallCount == 1)
    #expect(model.codexAccountStatus == .signedOut)
  }

  @MainActor
  private func waitForStatusRead(_ provider: TrackingStatusProvider) async {
    for _ in 0..<100 {
      if await provider.statusCallCount > 0 {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Codex status refresh did not complete within the test budget.")
  }

  private actor EmptySettingsStore: HexInferenceBackendSettingsStore {
    func load() async throws -> HexInferenceBackendSettings? {
      nil
    }

    func save(_ settings: HexInferenceBackendSettings) async throws {}
  }

  private actor EmptySecretStore: HexSecretStore {
    func secret(for key: HexSecretKey) async throws -> String {
      throw TestError.missingSecret
    }

    func exists(_ key: HexSecretKey) async throws -> Bool {
      false
    }

    func save(_ secret: String, for key: HexSecretKey) async throws {}

    func delete(_ key: HexSecretKey) async throws {}
  }

  private actor TrackingStatusProvider: CodexCompatibilityAccountStatusProviding {
    private(set) var statusCallCount = 0

    func status() async -> CodexCompatibilityAccountStatus {
      statusCallCount += 1
      return .signedOut
    }
  }

  private enum TestError: Error, Sendable {
    case missingSecret
  }
}
