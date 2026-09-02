import Foundation
import HexCore
import HexPersistence
import HexProviders

/// App-composition dependencies for inference-backend settings.
///
/// The optional factory is intentionally injected: the settings model does not construct process
/// channels or read account credentials. A live factory only launches an existing executable when
/// the user explicitly asks to refresh Codex compatibility status.
nonisolated struct HexInferenceBackendSettingsDependencies: Sendable {
  let settingsStore: (any HexInferenceBackendSettingsStore)?
  let secretStore: (any HexSecretStore)?
  let makeCodexStatusProvider:
    (
      @Sendable (HexCodexCompatibilitySettings) throws
        -> any CodexCompatibilityAccountStatusProviding
    )?

  static let blocked = Self(
    settingsStore: nil,
    secretStore: nil,
    makeCodexStatusProvider: nil
  )

  /// Creates the production settings boundary beneath the user's Application Support directory.
  ///
  /// Backend setup is independent of the currently selected gateway route, so Release builds keep
  /// the settings UI backed by the same owner-only JSON and Keychain stores as the resident host.
  /// A failure to resolve Application Support leaves the model explicitly unavailable rather than
  /// falling back to an unprotected location.
  static func live(for _: HexGatewayRoute) -> Self {
    guard let paths = try? HexResidentDataPaths.live() else {
      return .blocked
    }
    guard
      let settingsStore = try? JSONHexInferenceBackendSettingsStore(
        fileURL: paths.directoryURL.appendingPathComponent(
          "inference-backends.json",
          isDirectory: false
        )
      )
    else {
      return .blocked
    }

    let secretStore = KeychainHexSecretStore()
    let clientVersion =
      (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
      ?? "production"
    let makeCodexStatusProvider:
      @Sendable (HexCodexCompatibilitySettings) throws
        -> any CodexCompatibilityAccountStatusProviding = { settings in
          guard let executableURL = settings.executableURL else {
            throw CodexStdioAppServerChannelError.invalidConfiguration
          }
          let channel = try CodexStdioAppServerChannel(
            executableURL: executableURL,
            workingDirectoryURL: settings.workingDirectoryURL
          )
          let configuration = try CodexAppServerConnectionConfiguration(
            clientVersion: clientVersion
          )
          return CodexAppServerCompatibilityAccountStatusProvider(
            configuration: configuration,
            channel: channel
          )
        }
    return Self(
      settingsStore: settingsStore,
      secretStore: secretStore,
      makeCodexStatusProvider: makeCodexStatusProvider
    )
  }
}
