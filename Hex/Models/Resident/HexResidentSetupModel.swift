import Foundation
import HexCore
import HexMCP
import Observation

@MainActor
@Observable
final class HexResidentSetupModel {
  var apiKey = ""
  var modelID: String
  var workspaceRoot: URL?
  var peekabooMCPEnabled = false
  var playwrightMCPEnabled = false
  var xcodeMCPEnabled = false
  var authorizationMode = HexAuthorizationMode.askEveryTime
  private(set) var httpMCPServers: [HexHTTPMCPServer] = []

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredAPIKey = false
  private(set) var peekabooAvailability = MCPManagedToolAvailability.unavailable
  private(set) var playwrightAvailability = MCPManagedToolAvailability.unavailable
  private(set) var isInstallingPeekaboo = false
  private(set) var isInstallingPlaywright = false
  private(set) var isRequestingScreenControl = false
  private(set) var screenControlPermissionsGranted: Bool?
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var saveGeneration = 0

  private let settingsStore: (any HexResidentRuntimeSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private let managedToolLayout: MCPManagedToolLayout?
  private let managedToolInstaller: (any HexManagedToolInstalling)?
  private var hasLoaded = false
  private var loadedMCPServers: [HexResidentMCPServerSettings] = []

  init(
    initialModelID: String = "",
    settingsStore: (any HexResidentRuntimeSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    managedToolLayout: MCPManagedToolLayout? = nil,
    managedToolInstaller: (any HexManagedToolInstalling)? = nil
  ) {
    modelID = initialModelID
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.managedToolLayout = managedToolLayout
    self.managedToolInstaller = managedToolInstaller
  }

  var workspaceDisplayName: String {
    workspaceRoot?.path ?? "Choose a workspace folder"
  }

  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && settingsStore != nil && secretStore != nil
  }

  var hasValidCoreSettings: Bool {
    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidModelID(normalizedModelID), let workspaceRoot else {
      return false
    }
    return Self.isValidWorkspaceRoot(workspaceRoot)
  }

  func load() async {
    guard !hasLoaded, !isLoading else { return }
    hasLoaded = true
    isLoading = true
    defer { isLoading = false }

    if let managedToolLayout {
      peekabooAvailability = managedToolLayout.availability(for: .peekaboo)
      playwrightAvailability = managedToolLayout.availability(for: .playwright)
    }

    guard let settingsStore, let secretStore else {
      statusMessage = nil
      errorMessage = "Resident setup is unavailable in this build."
      return
    }

    do {
      if let settings = try await settingsStore.load() {
        modelID = settings.modelID
        workspaceRoot = settings.workspaceRoot
        authorizationMode = settings.authorizationMode
        loadedMCPServers = settings.mcpServers
        httpMCPServers = settings.mcpServers.compactMap { setting in
          guard setting.transport == .streamableHTTP, let endpointURL = setting.endpointURL else {
            return nil
          }
          return HexHTTPMCPServer(
            serverID: setting.serverID,
            endpointURL: endpointURL,
            isEnabled: setting.isEnabled
          )
        }
        peekabooMCPEnabled = settings.mcpServers.contains {
          $0.serverID == "peekaboo" && $0.transport == .peekaboo && $0.isEnabled
        }
        playwrightMCPEnabled = settings.mcpServers.contains {
          $0.serverID == "playwright" && $0.transport == .playwright && $0.isEnabled
        }
        xcodeMCPEnabled = settings.mcpServers.contains {
          $0.serverID == "xcode" && $0.transport == .xcode && $0.isEnabled
        }
      }
      hasStoredAPIKey = try await secretStore.exists(.openAIAPIKey)
      errorMessage = nil
      statusMessage = "Resident settings are ready to edit."
    } catch {
      errorMessage = Self.safeLoadMessage(for: error)
      statusMessage = nil
    }
  }

  func chooseWorkspace(_ url: URL) {
    guard url.isFileURL else {
      errorMessage = "Choose a local folder for the resident workspace."
      return
    }
    workspaceRoot = url.standardizedFileURL
    errorMessage = nil
    statusMessage = nil
  }

  func reportWorkspaceSelectionFailure() {
    errorMessage = "The workspace folder could not be selected."
    statusMessage = nil
  }

  func setPlaywrightEnabled(_ isEnabled: Bool) {
    guard isEnabled else {
      playwrightMCPEnabled = false
      return
    }
    installManagedTool(.playwright)
  }

  func setPeekabooEnabled(_ isEnabled: Bool) {
    guard isEnabled else {
      peekabooMCPEnabled = false
      return
    }
    installManagedTool(.peekaboo)
  }

  func refreshScreenControlPermissions() async {
    guard peekabooAvailability == .ready, let managedToolInstaller else {
      screenControlPermissionsGranted = nil
      return
    }
    do {
      screenControlPermissionsGranted =
        try await managedToolInstaller
        .screenControlPermissionStatus()
    } catch {
      screenControlPermissionsGranted = nil
    }
  }

  func requestScreenControlPermissions() {
    guard !isRequestingScreenControl, let managedToolInstaller else {
      errorMessage = "Screen control is unavailable in this build."
      return
    }
    isRequestingScreenControl = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let isGranted = try await managedToolInstaller.requestScreenControlPermission()
        peekabooAvailability = .ready
        peekabooMCPEnabled = true
        screenControlPermissionsGranted = isGranted
        statusMessage =
          isGranted
          ? "Screen control permissions are ready."
          : "Allow the requested Mac permissions in System Settings, then return to Hex."
      } catch is CancellationError {
        // The owning view disappeared; preserve the last verified state.
      } catch {
        errorMessage = Self.safeManagedToolMessage(error)
        statusMessage = nil
      }
      isRequestingScreenControl = false
    }
  }

  private func installManagedTool(_ tool: MCPManagedTool) {
    let availability = managedToolLayout?.availability(for: tool) ?? .unavailable
    if availability == .ready {
      setManagedTool(tool, enabled: true, availability: .ready)
      return
    }
    guard let managedToolInstaller else {
      errorMessage = "This capability cannot be installed in the current build."
      return
    }
    guard !isInstallingPeekaboo, !isInstallingPlaywright else { return }
    setInstalling(tool, true)
    errorMessage = nil
    statusMessage = "Installing \(displayName(for: tool))…"
    Task { [weak self] in
      guard let self else { return }
      do {
        try await managedToolInstaller.install(tool)
        setManagedTool(tool, enabled: true, availability: .ready)
        statusMessage = "\(displayName(for: tool)) is ready."
        errorMessage = nil
      } catch is CancellationError {
        // The owning view disappeared; do not convert cancellation into an installation failure.
      } catch {
        setManagedTool(tool, enabled: false, availability: .unavailable)
        errorMessage = Self.safeManagedToolMessage(error)
        statusMessage = nil
      }
      setInstalling(tool, false)
    }
  }

  private func setManagedTool(
    _ tool: MCPManagedTool,
    enabled: Bool,
    availability: MCPManagedToolAvailability
  ) {
    switch tool {
    case .playwright:
      playwrightMCPEnabled = enabled
      playwrightAvailability = availability
    case .peekaboo:
      peekabooMCPEnabled = enabled
      peekabooAvailability = availability
    }
  }

  private func setInstalling(_ tool: MCPManagedTool, _ isInstalling: Bool) {
    switch tool {
    case .playwright:
      isInstallingPlaywright = isInstalling
    case .peekaboo:
      isInstallingPeekaboo = isInstalling
    }
  }

  private func displayName(for tool: MCPManagedTool) -> String {
    switch tool {
    case .playwright: "Browser control"
    case .peekaboo: "Screen control"
    }
  }

  func addHTTPMCPServer(serverID: String, endpoint: String) -> Bool {
    let normalizedServerID = serverID.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let reservedServerIDs: Set<String> = ["peekaboo", "playwright", "xcode"]
    guard
      !reservedServerIDs.contains(normalizedServerID),
      !httpMCPServers.contains(where: { $0.serverID == normalizedServerID }),
      let endpointURL = URL(string: normalizedEndpoint),
      let setting = try? HexResidentMCPServerSettings(
        serverID: normalizedServerID,
        transport: .streamableHTTP,
        endpointURL: endpointURL
      ),
      let validatedEndpointURL = setting.endpointURL
    else {
      errorMessage =
        "Enter a unique lowercase server ID and an HTTPS or localhost HTTP MCP endpoint."
      statusMessage = nil
      return false
    }
    httpMCPServers.append(
      HexHTTPMCPServer(
        serverID: setting.serverID,
        endpointURL: validatedEndpointURL,
        isEnabled: true
      )
    )
    httpMCPServers.sort { $0.serverID < $1.serverID }
    errorMessage = nil
    statusMessage = nil
    return true
  }

  func setHTTPMCPServerEnabled(_ serverID: String, isEnabled: Bool) {
    guard let index = httpMCPServers.firstIndex(where: { $0.serverID == serverID }) else {
      return
    }
    httpMCPServers[index].isEnabled = isEnabled
    errorMessage = nil
    statusMessage = nil
  }

  func removeHTTPMCPServer(_ serverID: String) {
    httpMCPServers.removeAll { $0.serverID == serverID }
    errorMessage = nil
    statusMessage = nil
  }

  func save() {
    guard !isSaving else { return }
    errorMessage = nil
    statusMessage = nil

    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidModelID(normalizedModelID) else {
      errorMessage = "Enter a model identifier before saving."
      return
    }
    guard let workspaceRoot, Self.isValidWorkspaceRoot(workspaceRoot) else {
      errorMessage = "Choose an existing local workspace folder before saving."
      return
    }

    let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let settingsStore, let secretStore else {
      errorMessage = "Resident setup is unavailable in this build."
      return
    }
    guard !playwrightMCPEnabled || playwrightAvailability == .ready else {
      errorMessage = "Browser control is not ready yet."
      return
    }
    guard !peekabooMCPEnabled || peekabooAvailability == .ready else {
      errorMessage = "Screen control is not ready yet."
      return
    }

    let settings: HexResidentRuntimeSettings
    do {
      let builtInServerIDs: Set<String> = ["peekaboo", "playwright", "xcode"]
      var mcpServers = loadedMCPServers.filter {
        !builtInServerIDs.contains($0.serverID) && $0.transport != .streamableHTTP
      }
      mcpServers.append(
        contentsOf: try httpMCPServers.map { server in
          try HexResidentMCPServerSettings(
            serverID: server.serverID,
            transport: .streamableHTTP,
            endpointURL: server.endpointURL,
            isEnabled: server.isEnabled
          )
        }
      )
      if peekabooMCPEnabled {
        mcpServers.append(try .peekaboo())
      }
      if playwrightMCPEnabled {
        mcpServers.append(try .playwright())
      }
      if xcodeMCPEnabled {
        mcpServers.append(try .xcode())
      }
      settings = try HexResidentRuntimeSettings(
        modelID: normalizedModelID,
        workspaceRoot: workspaceRoot,
        mcpServers: mcpServers,
        authorizationMode: authorizationMode
      )
    } catch {
      errorMessage = Self.safeMessage(for: error)
      return
    }

    isSaving = true
    Task { [weak self] in
      guard let self else { return }
      do {
        // Settings and Keychain are separate stores; saving settings first keeps a failed settings
        // write from replacing a credential that the currently running gateway may still use.
        try await settingsStore.save(settings)
        if !normalizedAPIKey.isEmpty {
          try await secretStore.save(normalizedAPIKey, for: .openAIAPIKey)
        }
        hasStoredAPIKey = try await secretStore.exists(.openAIAPIKey)
        apiKey = ""
        modelID = normalizedModelID
        self.workspaceRoot = workspaceRoot
        loadedMCPServers = settings.mcpServers
        saveGeneration += 1
        statusMessage = "Resident settings saved."
        errorMessage = nil
        isSaving = false
      } catch is CancellationError {
        isSaving = false
      } catch {
        errorMessage = Self.safeMessage(for: error)
        statusMessage = nil
        isSaving = false
      }
    }
  }

  private static func isValidModelID(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 512 else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x21 && scalar.value <= 0x7E
    }
  }

  private static func safeManagedToolMessage(_ error: Error) -> String {
    if error is CancellationError {
      return "Capability installation was cancelled."
    }
    if let localizedError = error as? LocalizedError,
      let message = localizedError.errorDescription,
      !message.isEmpty
    {
      return message
    }
    return "Hex could not finish setting up this capability."
  }

  private static func isValidWorkspaceRoot(_ url: URL) -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      return false
    }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func safeMessage(for error: any Error) -> String {
    _ = error
    return "Resident settings could not be saved. Check the values and try again."
  }

  private static func safeLoadMessage(for error: any Error) -> String {
    _ = error
    return "Resident settings could not be loaded. Check the setup and try again."
  }
}
