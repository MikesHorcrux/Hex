/// Asynchronous persistence boundary for the non-secret resident runtime settings.
public protocol HexResidentRuntimeSettingsStore: Sendable {
  func load() async throws -> HexResidentRuntimeSettings?
  func save(_ settings: HexResidentRuntimeSettings) async throws
}
