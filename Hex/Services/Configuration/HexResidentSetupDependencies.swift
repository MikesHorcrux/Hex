import Foundation
import HexCore
import HexMCP
import HexPersistence

/// App-composition dependencies for resident setup and activation checks.
nonisolated struct HexResidentSetupDependencies: Sendable {
  let settingsStore: (any HexResidentRuntimeSettingsStore)?
  let secretStore: (any HexSecretStore)?
  let managedToolLayout: MCPManagedToolLayout?
  let readinessChecker: any HexGatewayActivationReadinessChecking

  static let blocked = Self(
    settingsStore: nil,
    secretStore: nil,
    managedToolLayout: nil,
    readinessChecker: HexBlockedGatewayActivationChecker()
  )

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
    guard
      let inferenceSettingsStore = try? JSONHexInferenceBackendSettingsStore(
        fileURL: paths.directoryURL.appendingPathComponent(
          "inference-backends.json",
          isDirectory: false
        )
      ),
      let managedToolLayout = try? MCPManagedToolLayout(
        rootURL: paths.directoryURL.appendingPathComponent("Tools", isDirectory: true)
      )
    else {
      return .blocked
    }
    let secretStore = KeychainHexSecretStore()
    let readinessChecker = HexResidentGatewayActivationChecker(
      settingsStore: settingsStore,
      secretStore: secretStore,
      appBundleURL: Bundle.main.bundleURL,
      managedToolLayout: managedToolLayout,
      inferenceSettingsStore: inferenceSettingsStore
    )
    return Self(
      settingsStore: settingsStore,
      secretStore: secretStore,
      managedToolLayout: managedToolLayout,
      readinessChecker: readinessChecker
    )
  }
}
