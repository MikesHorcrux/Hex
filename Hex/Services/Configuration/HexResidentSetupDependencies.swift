import Foundation
import HexCore
import HexPersistence

/// App-composition dependencies for resident setup and activation checks.
nonisolated struct HexResidentSetupDependencies: Sendable {
  let settingsStore: (any HexResidentRuntimeSettingsStore)?
  let secretStore: (any HexSecretStore)?
  let readinessChecker: any HexGatewayActivationReadinessChecking

  static let blocked = Self(
    settingsStore: nil,
    secretStore: nil,
    readinessChecker: HexBlockedGatewayActivationChecker()
  )

  #if DEBUG
    static func live(for route: HexGatewayRoute) -> Self {
      guard route.kind == .residentXPC,
        let paths = try? HexResidentDataPaths.live()
      else {
        return .blocked
      }

      guard let settingsStore = try? JSONHexResidentRuntimeSettingsStore(fileURL: paths.settingsURL)
      else {
        return .blocked
      }
      let secretStore = KeychainHexSecretStore()
      let readinessChecker = HexResidentGatewayActivationChecker(
        settingsStore: settingsStore,
        secretStore: secretStore,
        appBundleURL: Bundle.main.bundleURL
      )
      return Self(
        settingsStore: settingsStore,
        secretStore: secretStore,
        readinessChecker: readinessChecker
      )
    }
  #endif
}
