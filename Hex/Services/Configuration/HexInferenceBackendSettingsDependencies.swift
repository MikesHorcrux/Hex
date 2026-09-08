import Foundation
import HexCore
import HexPersistence
import HexProviders

/// App-composition dependencies for inference-backend settings.
nonisolated struct HexInferenceBackendSettingsDependencies: Sendable {
  let settingsStore: (any HexInferenceBackendSettingsStore)?
  let secretStore: (any HexSecretStore)?
  let chatGPTAuthorizationManager: (any ChatGPTCodexOAuthManaging)?
  let localModelInstaller: (any MLXLocalModelInstalling)?

  static let blocked = Self(
    settingsStore: nil,
    secretStore: nil,
    chatGPTAuthorizationManager: nil,
    localModelInstaller: nil
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
    return Self(
      settingsStore: settingsStore,
      secretStore: secretStore,
      chatGPTAuthorizationManager: ChatGPTCodexOAuthSession(secretStore: secretStore),
      localModelInstaller: HuggingFaceMLXLocalModelInstaller(
        rootURL: paths.directoryURL.appendingPathComponent("Models", isDirectory: true)
      )
    )
  }
}
