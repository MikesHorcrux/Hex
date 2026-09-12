/// Applies newly persisted resident settings to an already-running Hex Agent.
///
/// Saving and applying are deliberately separate boundaries: settings models own durable writes,
/// while the lifecycle model owns the supported service restart needed to load those writes.
@MainActor
protocol HexResidentConfigurationReloading: Sendable {
  func reloadAfterConfigurationChange() async throws
}
