import Foundation
import HexCore
import HexGatewayKit
import HexMCP
import HexPersistence

/// Read-only preflight for a signed resident gateway bundle.
///
/// The checker does not call `SMAppService` and does not read the credential value. It only asks the
/// injected secret store whether the OpenAI credential exists, then validates the settings and the
/// bundle layout required by the LaunchAgent contract.
nonisolated struct HexResidentGatewayActivationChecker: HexGatewayActivationReadinessChecking {
  private let settingsStore: any HexResidentRuntimeSettingsStore
  private let secretStore: any HexSecretStore
  private let appBundleURL: URL
  private let managedToolLayout: MCPManagedToolLayout?

  init(
    settingsStore: any HexResidentRuntimeSettingsStore,
    secretStore: any HexSecretStore,
    appBundleURL: URL,
    managedToolLayout: MCPManagedToolLayout? = nil
  ) {
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.appBundleURL = appBundleURL.standardizedFileURL
    self.managedToolLayout = managedToolLayout
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
    guard managedToolsAreReady(settings.mcpServers) else {
      return Self.blocked(
        "An enabled managed MCP tool is missing or incomplete. Check Agent Tools in Settings."
      )
    }

    guard await hasCredential() else {
      return Self.blocked("Resident setup is missing an OpenAI API key. Add one in Settings.")
    }

    let helperURL = appBundleURL.appendingPathComponent(
      "Contents/Resources/HexGateway",
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

  private func hasCredential() async -> Bool {
    do {
      return try await secretStore.exists(.openAIAPIKey)
    } catch {
      return false
    }
  }

  private func managedToolsAreReady(_ settings: [HexResidentMCPServerSettings]) -> Bool {
    for setting in settings where setting.isEnabled {
      let tool: MCPManagedTool?
      switch setting.transport {
      case .peekaboo:
        tool = .peekaboo
      case .playwright:
        tool = .playwright
      case .streamableHTTP, .xcode:
        tool = nil
      }
      if let tool, managedToolLayout?.availability(for: tool) != .ready {
        return false
      }
    }
    return true
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
