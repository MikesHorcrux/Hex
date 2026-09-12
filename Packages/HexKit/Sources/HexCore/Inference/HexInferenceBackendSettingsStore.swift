/// Asynchronous persistence boundary for non-secret inference-backend settings.
public protocol HexInferenceBackendSettingsStore: Sendable {
  func load() async throws -> HexInferenceBackendSettings?
  func save(_ settings: HexInferenceBackendSettings) async throws
}
