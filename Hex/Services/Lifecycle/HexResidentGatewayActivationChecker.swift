import Foundation
import HexCore
import HexGatewayKit
import HexMCP
import HexPersistence

/// Read-only preflight for a signed resident gateway bundle.
///
/// The checker does not call `SMAppService` or read credential values. It checks whether the
/// selected backend needs an OpenAI credential, then validates the settings and bundle layout
/// required by the LaunchAgent contract.
nonisolated struct HexResidentGatewayActivationChecker: HexGatewayActivationReadinessChecking {
  private let settingsStore: any HexResidentRuntimeSettingsStore
  private let secretStore: any HexSecretStore
  private let inferenceSettingsStore: (any HexInferenceBackendSettingsStore)?
  private let appBundleURL: URL

  init(
    settingsStore: any HexResidentRuntimeSettingsStore,
    secretStore: any HexSecretStore,
    appBundleURL: URL,
    managedToolLayout: MCPManagedToolLayout? = nil,
    inferenceSettingsStore: (any HexInferenceBackendSettingsStore)? = nil
  ) {
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.inferenceSettingsStore = inferenceSettingsStore
    self.appBundleURL = appBundleURL.standardizedFileURL
    // Kept as an input for source compatibility; optional tool installation is validated by its
    // deferred MCP session, not by core gateway activation.
    _ = managedToolLayout
  }

  func check() async -> HexGatewayActivationReadiness {
    let settings: HexResidentRuntimeSettings?
    do {
      settings = try await settingsStore.load()
    } catch {
      return Self.blocked("Resident settings could not be loaded. Check the setup and try again.")
    }
    guard let settings else {
      return Self.blocked(
        "Resident setup is incomplete. Open Settings and save a model and workspace.")
    }
    guard Self.isValid(settings: settings) else {
      return Self.blocked("Resident setup contains invalid model or workspace settings.")
    }

    if let inferenceSettingsStore {
      let inferenceSettings: HexInferenceBackendSettings?
      do {
        inferenceSettings = try await inferenceSettingsStore.load()
      } catch {
        return Self.blocked(
          "Inference backend settings could not be loaded. Check Inference in Settings."
        )
      }
      let resolvedInferenceSettings: HexInferenceBackendSettings
      do {
        resolvedInferenceSettings =
          try inferenceSettings
          ?? HexInferenceBackendSettings.migrationDefault(
            legacyOpenAIModelID: settings.modelID
          )
      } catch {
        return Self.blocked(
          "Inference backend settings could not be loaded. Check Inference in Settings."
        )
      }
      if resolvedInferenceSettings.selectedBackend == .openAIResponses,
        !(await hasAuthorization(for: resolvedInferenceSettings.openAI.authenticationMethod))
      {
        return Self.blocked(
          Self.missingAuthorizationMessage(
            for: resolvedInferenceSettings.openAI.authenticationMethod
          )
        )
      }
    } else if !(await hasAuthorization(for: .apiKey)) {
      return Self.blocked("Resident setup is missing an OpenAI API key. Add one in Settings.")
    }

    let helperURL = appBundleURL.appendingPathComponent(
      HexGatewayServiceIdentity.bundledExecutablePath,
      isDirectory: false
    )
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      return Self.blocked(
        "The resident gateway helper is missing or not executable in this app bundle.")
    }

    let plistURL = appBundleURL.appendingPathComponent(
      "Contents/Library/LaunchAgents/com.lunarmothstudios.hex.gateway.plist",
      isDirectory: false
    )
    guard let plist = Self.loadLaunchAgentPlist(at: plistURL) else {
      return Self.blocked("The resident gateway LaunchAgent plist is missing or invalid.")
    }
    guard plist["BundleProgram"] as? String == HexGatewayServiceIdentity.bundledExecutablePath
    else {
      return Self.blocked("The resident gateway LaunchAgent points to the wrong helper path.")
    }
    guard Self.isValidLaunchAgentPlist(plist) else {
      return Self.blocked("The resident gateway LaunchAgent plist is incomplete or invalid.")
    }

    return .ready
  }

  private func hasAuthorization(for method: HexOpenAIAuthenticationMethod) async -> Bool {
    let key: HexSecretKey = method == .chatGPT ? .openAIChatGPTOAuth : .openAIAPIKey
    do {
      return try await secretStore.exists(key)
    } catch {
      return false
    }
  }

  private static func missingAuthorizationMessage(
    for method: HexOpenAIAuthenticationMethod
  ) -> String {
    switch method {
    case .chatGPT:
      "Resident setup needs ChatGPT sign-in. Open Inference in Settings and sign in."
    case .apiKey:
      "Resident setup is missing an OpenAI API key. Add one in Settings."
    }
  }

  private static func isValid(settings: HexResidentRuntimeSettings) -> Bool {
    let modelID = settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !modelID.isEmpty, modelID.utf8.count <= 512 else {
      return false
    }
    guard settings.workspaceRoot.isFileURL,
      settings.workspaceRoot.path.hasPrefix("/"),
      !settings.workspaceRoot.path.contains("\0")
    else {
      return false
    }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: settings.workspaceRoot.path,
      isDirectory: &isDirectory
    ) && isDirectory.boolValue
  }

  private static func loadLaunchAgentPlist(at url: URL) -> [String: Any]? {
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      return nil
    }
    do {
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      let object = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
      return object as? [String: Any]
    } catch {
      return nil
    }
  }

  private static func isValidLaunchAgentPlist(_ plist: [String: Any]) -> Bool {
    guard
      plist["Label"] as? String == HexGatewayServiceIdentity.launchAgentLabel,
      let machServices = plist["MachServices"] as? [String: Any],
      machServices[HexGatewayServiceIdentity.machServiceName] as? Bool == true,
      plist["RunAtLoad"] as? Bool == true,
      let keepAlive = plist["KeepAlive"] as? [String: Any],
      keepAlive["SuccessfulExit"] as? Bool == false,
      let throttleInterval = plist["ThrottleInterval"] as? NSNumber,
      throttleInterval.intValue > 0
    else {
      return false
    }
    return true
  }

  private static func blocked(_ message: String) -> HexGatewayActivationReadiness {
    HexGatewayActivationReadiness(isReady: false, message: message)
  }
}
