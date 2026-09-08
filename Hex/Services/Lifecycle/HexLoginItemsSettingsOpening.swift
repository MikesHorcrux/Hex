/// The explicit, user-invoked action for opening macOS Login Items settings when a service needs
/// approval. Keeping it separate from status and registration makes refresh operations inert.
nonisolated protocol HexLoginItemsSettingsOpening: Sendable {
  func openLoginItemsSettings() async
}
