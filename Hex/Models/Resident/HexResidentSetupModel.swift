import Foundation
import HexCore
import HexIPC
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
  /// Loaded saved policy, or the exact policy whose save/apply completed. Never the editable draft.
  private(set) var savedAuthorizationMode: HexAuthorizationMode?
  private(set) var httpMCPServers: [HexHTTPMCPServer] = []

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredAPIKey = false
  private(set) var peekabooAvailability = MCPManagedToolAvailability.unavailable
  private(set) var playwrightAvailability = MCPManagedToolAvailability.unavailable
  private(set) var isInstallingPeekaboo = false
  private(set) var isInstallingPlaywright = false
  private(set) var isRequestingScreenControl = false
  private(set) var isCheckingScreenControl = false
  private(set) var screenControlPermissionError: String?
  let folderAccess: HexFolderAccessModel
  private(set) var screenControlPermissionStatus: GatewayScreenControlPermissionStatus?
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var saveGeneration = 0

  private let settingsStore: (any HexResidentRuntimeSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private let managedToolLayout: MCPManagedToolLayout?
  private let managedToolInstaller: (any HexManagedToolInstalling)?
  private let screenControlPermissionService: (any HexScreenControlPermissionServicing)?
  private let configurationReloader: (any HexResidentConfigurationReloading)?
  private var hasLoaded = false
  private var hasAttemptedLoad = false
  private var loadedMCPServers: [HexResidentMCPServerSettings] = []
  @ObservationIgnored private var screenPermissionTask: Task<Void, Never>?
  private var permissionGeneration = UUID()

  init(
    initialModelID: String = "",
    settingsStore: (any HexResidentRuntimeSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    managedToolLayout: MCPManagedToolLayout? = nil,
    managedToolInstaller: (any HexManagedToolInstalling)? = nil,
    screenControlPermissionService: (any HexScreenControlPermissionServicing)? = nil,
    permissionManagementService: (any HexPermissionManaging)? = nil,
    configurationReloader: (any HexResidentConfigurationReloading)? = nil
  ) {
    modelID = initialModelID
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.managedToolLayout = managedToolLayout
    self.managedToolInstaller = managedToolInstaller
    self.screenControlPermissionService = screenControlPermissionService
    folderAccess = HexFolderAccessModel(service: permissionManagementService)
    self.configurationReloader = configurationReloader
  }

  var screenControlPermissionsGranted: Bool? {
    screenControlPermissionStatus?.isGranted
  }

  var screenControlBundleURL: URL? {
    managedToolLayout?.peekabooExecutableURL
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  var isInstallingManagedTool: Bool {
    isInstallingPeekaboo || isInstallingPlaywright
  }

  var needsLoadRetry: Bool {
    hasAttemptedLoad && !hasLoaded && !isLoading
  }

  var browserSetupStatus: HexCapabilitySetupStatus {
    .browser(
      enabled: playwrightMCPEnabled,
      savedEnabled: loadedMCPServers.contains { $0.transport == .playwright && $0.isEnabled },
      installed: playwrightAvailability == .ready,
      installing: isInstallingPlaywright
    )
  }

  var screenSetupStatus: HexCapabilitySetupStatus {
    .screen(
      enabled: peekabooMCPEnabled,
      savedEnabled: loadedMCPServers.contains { $0.transport == .peekaboo && $0.isEnabled },
      installed: peekabooAvailability == .ready,
      checking: isRequestingScreenControl || isInstallingPeekaboo || isCheckingScreenControl,
      permissionsGranted: screenControlPermissionsGranted
    )
  }

  var workspaceDisplayName: String {
    workspaceRoot?.path ?? "Choose a workspace folder"
  }

  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && !isInstallingManagedTool && !isRequestingScreenControl
      && settingsStore != nil && secretStore != nil
  }

  var hasValidCoreSettings: Bool {
    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard hasLoaded, Self.isValidModelID(normalizedModelID), let workspaceRoot else {
      return false
    }
    return Self.isValidWorkspaceRoot(workspaceRoot)
  }

  func load() async {
    guard !hasLoaded, !isLoading else { return }
    hasAttemptedLoad = true
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
      let settings = try await settingsStore.load()
      let storedAPIKeyExists = try await secretStore.exists(.openAIAPIKey)
      try Task.checkCancellation()
      if let settings {
        modelID = settings.modelID
        workspaceRoot = settings.workspaceRoot
        authorizationMode = settings.authorizationMode
        savedAuthorizationMode = settings.authorizationMode
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
      hasStoredAPIKey = storedAPIKeyExists
      hasLoaded = true
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
    guard !isRequestingScreenControl, !isCheckingScreenControl, !isInstallingPeekaboo else {
      return
    }
    if let managedToolLayout {
      peekabooAvailability = managedToolLayout.availability(for: .peekaboo)
    }
    screenControlPermissionError = nil
    screenControlPermissionStatus = nil
    guard peekabooAvailability == .ready, let screenControlPermissionService else {
      return
    }
    isCheckingScreenControl = true
    let expected = permissionGeneration
    defer { isCheckingScreenControl = false }
    do {
      let status = try await screenControlPermissionService.screenControlPermissionStatus()
      try Task.checkCancellation()
      guard permissionGeneration == expected else { return }
      screenControlPermissionStatus = status
    } catch {
      guard permissionGeneration == expected else { return }
      if !(error is CancellationError) {
        screenControlPermissionError = Self.safeManagedToolMessage(error)
      }
    }
  }

  func invalidateVerifiedPermissions() {
    permissionGeneration = UUID()
    screenControlPermissionStatus = nil
    folderAccess.invalidate()
  }

  func requestScreenControlPermissions() {
    guard
      !isRequestingScreenControl, !isCheckingScreenControl, !isInstallingManagedTool, !isSaving,
      let managedToolInstaller,
      let screenControlPermissionService
    else {
      errorMessage = "Screen control is unavailable in this build."
      return
    }
    isRequestingScreenControl = true
    let expected = permissionGeneration
    screenControlPermissionError = nil
    screenControlPermissionStatus = nil
    errorMessage = nil
    screenPermissionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isRequestingScreenControl = false
        screenPermissionTask = nil
      }
      do {
        try await managedToolInstaller.install(.peekaboo)
        let permissionStatus =
          try await screenControlPermissionService.requestScreenControlPermission()
        try Task.checkCancellation()
        guard permissionGeneration == expected else { return }
        peekabooAvailability = .ready
        screenControlPermissionStatus = permissionStatus
        statusMessage =
          permissionStatus.isGranted
          ? "Screen control permissions are ready."
          : "Allow the requested Mac permissions in System Settings, then return to Hex."
      } catch is CancellationError {
        // This bounded operation belongs to the app's setup model, not a settings tab's lifetime.
        if permissionGeneration == expected { screenControlPermissionStatus = nil }
      } catch {
        guard permissionGeneration == expected else { return }
        screenControlPermissionStatus = nil
        errorMessage = Self.safeManagedToolMessage(error)
        screenControlPermissionError = errorMessage
        statusMessage = nil
      }
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
        statusMessage = "\(displayName(for: tool)) is installed."
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
    guard let request = prepareSave() else { return }
    Task { [weak self] in
      _ = await self?.persist(request)
    }
  }

  /// Completes only after persistence and the resident reload have both succeeded.
  func saveAndWait() async -> Bool {
    guard let request = prepareSave() else { return false }
    return await persist(request)
  }

  private func prepareSave() -> SaveRequest? {
    guard !isSaving, !Task.isCancelled else { return nil }
    guard hasLoaded else {
      errorMessage = "Load the saved resident settings before making changes."
      statusMessage = nil
      return nil
    }
    guard !isInstallingManagedTool, !isRequestingScreenControl else {
      errorMessage = "Wait for browser or screen control to finish setting up, then continue."
      statusMessage = nil
      return nil
    }
    errorMessage = nil
    statusMessage = nil

    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidModelID(normalizedModelID) else {
      errorMessage = "Enter a model identifier before saving."
      return nil
    }
    guard let workspaceRoot, Self.isValidWorkspaceRoot(workspaceRoot) else {
      errorMessage = "Choose an existing local workspace folder before saving."
      return nil
    }

    let normalizedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard settingsStore != nil, secretStore != nil else {
      errorMessage = "Resident setup is unavailable in this build."
      return nil
    }
    guard !playwrightMCPEnabled || playwrightAvailability == .ready else {
      errorMessage = "Browser control is not ready yet."
      return nil
    }
    guard !peekabooMCPEnabled || peekabooAvailability == .ready else {
      errorMessage = "Screen control is not ready yet."
      return nil
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
      return nil
    }

    isSaving = true
    return SaveRequest(settings: settings, apiKey: normalizedAPIKey)
  }

  private func persist(_ request: SaveRequest) async -> Bool {
    defer { isSaving = false }
    guard let settingsStore, let secretStore else { return false }
    var isReloading = false
    do {
      try Task.checkCancellation()
      // Keep settings and credential persistence separate; a failed settings write cannot replace
      // a credential still used by the resident. The awaited result covers both stores and reload.
      try await settingsStore.save(request.settings)
      if !request.apiKey.isEmpty {
        try await secretStore.save(request.apiKey, for: .openAIAPIKey)
      }
      hasStoredAPIKey = try await secretStore.exists(.openAIAPIKey)
      apiKey = ""
      modelID = request.settings.modelID
      workspaceRoot = request.settings.workspaceRoot
      loadedMCPServers = request.settings.mcpServers
      try Task.checkCancellation()
      isReloading = true
      try await configurationReloader?.reloadAfterConfigurationChange()
      try Task.checkCancellation()
      savedAuthorizationMode = request.settings.authorizationMode
      saveGeneration += 1
      statusMessage = "Resident settings saved."
      errorMessage = nil
      return true
    } catch is CancellationError {
      return false
    } catch {
      errorMessage =
        isReloading
        ? "Settings were saved, but Hex Agent could not apply them. Try saving again."
        : Self.safeMessage(for: error)
      statusMessage = nil
      return false
    }
  }

  private struct SaveRequest: Sendable {
    let settings: HexResidentRuntimeSettings
    let apiKey: String
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
