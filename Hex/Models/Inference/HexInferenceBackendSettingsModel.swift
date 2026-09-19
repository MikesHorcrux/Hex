import Foundation
import HexCore
import HexProviders
import Observation

/// Main-actor settings model for selecting and validating Hex inference backends.
///
/// The API-key field is a transient edit buffer. ChatGPT tokens never enter this model: the
/// injected OAuth manager owns them and persists one atomic bundle directly to Keychain.
@MainActor
@Observable
final class HexInferenceBackendSettingsModel {
  static let recommendedLocalModelID = "mlx-community/Qwen3-4B-4bit"
  static let recommendedLocalModelName = "Qwen 3 4B"

  var selectedBackend: HexInferenceBackendKind
  var openAIAuthenticationMethod: HexOpenAIAuthenticationMethod
  var openAIModelID: String
  var openAIAPIKey = ""

  var mlxModelID: String {
    didSet {
      if oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        != mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
      {
        mlxDirectory = nil
      }
    }
  }
  var mlxDisplayName: String
  var mlxDirectory: URL?
  var mlxContextWindow = ""
  var mlxMaximumOutputTokens = "2048"
  var mlxSupportsToolCalling = false
  var mlxSupportsParallelToolCalling = false

  var llamaModelID: String
  var llamaDisplayName: String
  var llamaEndpoint: String
  var llamaContextWindow = ""
  var llamaMaximumOutputTokens = "2048"
  var llamaSupportsToolCalling = false
  var llamaSupportsParallelToolCalling = false

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredOpenAIAPIKey = false
  private(set) var chatGPTAccountStatus = ChatGPTCodexOAuthAccountStatus.signedOut
  private(set) var chatGPTLoginChallenge: ChatGPTCodexDeviceAuthorizationChallenge?
  private(set) var isChatGPTLoginInProgress = false
  private(set) var isChatGPTLogoutInProgress = false
  private(set) var isInstallingLocalModel = false
  private(set) var localModelDownloadProgress: Double?
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var saveGeneration = 0
  private(set) var persistedSettings: HexInferenceBackendSettings?

  private let settingsStore: (any HexInferenceBackendSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private let chatGPTAuthorizationManager: (any ChatGPTCodexOAuthManaging)?
  private let localModelInstaller: (any MLXLocalModelInstalling)?
  private let configurationReloader: (any HexResidentConfigurationReloading)?
  private var hasLoaded = false
  private var hasAttemptedLoad = false
  private var accountActionGeneration = 0
  @ObservationIgnored private var accountActionTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Bool, Never>?
  private var saveOperationID: UUID?

  init(
    settingsStore: (any HexInferenceBackendSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    chatGPTAuthorizationManager: (any ChatGPTCodexOAuthManaging)? = nil,
    localModelInstaller: (any MLXLocalModelInstalling)? = nil,
    configurationReloader: (any HexResidentConfigurationReloading)? = nil
  ) {
    selectedBackend = .openAIResponses
    openAIAuthenticationMethod = .chatGPT
    openAIModelID = HexInferenceBackendSettings.defaultOpenAIModelID
    mlxModelID = ""
    mlxDisplayName = ""
    llamaModelID = ""
    llamaDisplayName = ""
    llamaEndpoint = ""
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.chatGPTAuthorizationManager = chatGPTAuthorizationManager
    self.localModelInstaller = localModelInstaller
    self.configurationReloader = configurationReloader
  }

  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && !isInstallingLocalModel
      && settingsStore != nil && secretStore != nil
      && (selectedBackend != .mlxLocal || mlxDirectory != nil || localModelInstaller != nil)
      && (selectedBackend != .llamaCppLocal || !llamaEndpoint.isEmpty)
  }

  var setupChoice: HexInferenceSetupChoice {
    get {
      switch selectedBackend {
      case .mlxLocal:
        .onThisMac
      case .openAIResponses:
        openAIAuthenticationMethod == .chatGPT ? .chatGPT : .openAIAPI
      case .llamaCppLocal:
        .localGGUF
      }
    }
    set {
      switch newValue {
      case .chatGPT:
        selectedBackend = .openAIResponses
        openAIAuthenticationMethod = .chatGPT
      case .openAIAPI:
        selectedBackend = .openAIResponses
        openAIAuthenticationMethod = .apiKey
      case .onThisMac:
        selectedBackend = .mlxLocal
        if mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          mlxModelID = Self.recommendedLocalModelID
        }
        if mlxDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          mlxDisplayName = Self.recommendedLocalModelName
        }
        mlxSupportsToolCalling = true
      case .localGGUF:
        selectedBackend = .llamaCppLocal
        if llamaModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          llamaModelID = "Bonsai-27b-1bit-CRACK-Q1_0"
        }
        if llamaDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          llamaDisplayName = "Bonsai 2 27B (GGUF)"
        }
        if llamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          llamaEndpoint = "http://127.0.0.1:8080"
        }
        llamaSupportsToolCalling = true
      }
      errorMessage = nil
      updateCredentialStatusMessage()
    }
  }

  var needsLocalModelDownload: Bool {
    selectedBackend == .mlxLocal && mlxDirectory == nil
  }

  var effectiveModelID: String {
    switch selectedBackend {
    case .openAIResponses:
      openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    case .mlxLocal:
      mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    case .llamaCppLocal:
      llamaModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  /// The immutable persisted choice, never an in-flight or unsaved form edit.
  var savedModelID: String? {
    guard let persistedSettings else { return nil }
    switch persistedSettings.selectedBackend {
    case .openAIResponses: return persistedSettings.openAI.modelID
    case .mlxLocal: return persistedSettings.mlx.modelID
    case .llamaCppLocal: return persistedSettings.llamaCpp.modelID
    }
  }

  var needsLoadRetry: Bool { hasAttemptedLoad && !hasLoaded && !isLoading }

  var mlxDirectoryDisplayName: String {
    mlxDirectory?.path ?? "Choose an existing model folder"
  }

  func load() async {
    guard !hasLoaded, !isLoading else { return }
    hasAttemptedLoad = true
    isLoading = true
    defer { isLoading = false }

    guard let settingsStore, let secretStore else {
      errorMessage = "Inference backend settings are unavailable in this build."
      chatGPTAccountStatus = .unavailable
      return
    }

    do {
      if let settings = try await settingsStore.load() {
        apply(settings)
        persistedSettings = settings
      }
      hasStoredOpenAIAPIKey = try await secretStore.exists(.openAIAPIKey)
      if let chatGPTAuthorizationManager {
        chatGPTAccountStatus = await chatGPTAuthorizationManager.accountStatus()
      } else {
        chatGPTAccountStatus = .unavailable
      }
      errorMessage = nil
      hasLoaded = true
      updateCredentialStatusMessage()
    } catch {
      errorMessage =
        "Inference backend settings could not be loaded. Check the setup and try again."
      statusMessage = nil
      chatGPTAccountStatus = .unavailable
    }
  }

  func chooseMLXDirectory(_ url: URL) {
    guard Self.isExistingDirectory(url) else {
      errorMessage = "Choose an existing local model folder."
      statusMessage = nil
      return
    }
    mlxDirectory = url.standardizedFileURL
    errorMessage = nil
    statusMessage = "The local model folder will be checked when you save."
  }

  func errorMessageForFileSelectionFailure() {
    errorMessage = "The selected file or folder could not be used."
    statusMessage = nil
  }

  func refreshChatGPTAccountStatus() {
    guard let chatGPTAuthorizationManager else {
      chatGPTAccountStatus = .unavailable
      return
    }
    accountActionGeneration += 1
    let generation = accountActionGeneration
    Task { [weak self] in
      let status = await chatGPTAuthorizationManager.accountStatus()
      guard let self, self.accountActionGeneration == generation else { return }
      self.chatGPTAccountStatus = status
      self.updateCredentialStatusMessage()
    }
  }

  func startChatGPTLogin() {
    guard
      !isChatGPTLoginInProgress,
      !isChatGPTLogoutInProgress,
      chatGPTLoginChallenge == nil,
      let chatGPTAuthorizationManager
    else { return }

    accountActionGeneration += 1
    let generation = accountActionGeneration
    isChatGPTLoginInProgress = true
    errorMessage = nil
    statusMessage = "Starting ChatGPT sign-in…"
    accountActionTask = Task { [weak self] in
      do {
        let challenge = try await chatGPTAuthorizationManager.startDeviceAuthorization()
        guard let self, self.accountActionGeneration == generation else { return }
        self.chatGPTLoginChallenge = challenge
        self.isChatGPTLoginInProgress = false
        self.statusMessage = "Open the verification page, enter the code, then finish sign-in."
        self.accountActionTask = nil
      } catch is CancellationError {
        guard let self, self.accountActionGeneration == generation else { return }
        self.isChatGPTLoginInProgress = false
        self.accountActionTask = nil
      } catch {
        guard let self, self.accountActionGeneration == generation else { return }
        self.isChatGPTLoginInProgress = false
        self.statusMessage = nil
        self.errorMessage = Self.messageForChatGPTAccountAction(error)
        self.accountActionTask = nil
      }
    }
  }

  func completeChatGPTLogin() {
    guard
      !isChatGPTLoginInProgress,
      !isChatGPTLogoutInProgress,
      let challenge = chatGPTLoginChallenge,
      let chatGPTAuthorizationManager
    else { return }

    accountActionGeneration += 1
    let generation = accountActionGeneration
    isChatGPTLoginInProgress = true
    errorMessage = nil
    statusMessage = "Waiting for ChatGPT approval…"
    accountActionTask = Task { [weak self] in
      do {
        try await chatGPTAuthorizationManager.completeDeviceAuthorization(challenge)
        guard let self, self.accountActionGeneration == generation else { return }
        self.chatGPTLoginChallenge = nil
        self.isChatGPTLoginInProgress = false
        self.chatGPTAccountStatus = .signedIn
        self.statusMessage = "Signed in. Hex will use ChatGPT only for model inference."
        self.errorMessage = nil
        self.accountActionTask = nil
      } catch is CancellationError {
        guard let self, self.accountActionGeneration == generation else { return }
        self.isChatGPTLoginInProgress = false
        self.accountActionTask = nil
      } catch {
        guard let self, self.accountActionGeneration == generation else { return }
        self.chatGPTLoginChallenge = nil
        self.isChatGPTLoginInProgress = false
        self.statusMessage = nil
        self.errorMessage = Self.messageForChatGPTAccountAction(error)
        self.accountActionTask = nil
      }
    }
  }

  func cancelChatGPTLogin() {
    accountActionGeneration += 1
    accountActionTask?.cancel()
    accountActionTask = nil
    chatGPTLoginChallenge = nil
    isChatGPTLoginInProgress = false
    errorMessage = nil
    statusMessage = "ChatGPT sign-in cancelled."
  }

  func signOutChatGPT() {
    guard
      !isChatGPTLoginInProgress,
      !isChatGPTLogoutInProgress,
      let chatGPTAuthorizationManager
    else { return }

    accountActionGeneration += 1
    let generation = accountActionGeneration
    isChatGPTLogoutInProgress = true
    errorMessage = nil
    statusMessage = "Signing out of ChatGPT…"
    accountActionTask = Task { [weak self] in
      do {
        try await chatGPTAuthorizationManager.signOut()
        guard let self, self.accountActionGeneration == generation else { return }
        self.isChatGPTLogoutInProgress = false
        self.chatGPTAccountStatus = .signedOut
        self.statusMessage = "Signed out of ChatGPT."
        self.accountActionTask = nil
      } catch is CancellationError {
        guard let self, self.accountActionGeneration == generation else { return }
        self.isChatGPTLogoutInProgress = false
        self.accountActionTask = nil
      } catch {
        guard let self, self.accountActionGeneration == generation else { return }
        self.isChatGPTLogoutInProgress = false
        self.statusMessage = nil
        self.errorMessage = Self.messageForChatGPTAccountAction(error)
        self.accountActionTask = nil
      }
    }
  }

  func save() {
    guard !isSaving, !isInstallingLocalModel else { return }
    saveTask = nil
    errorMessage = nil
    statusMessage = nil
    guard hasLoaded else {
      errorMessage = "Load the saved inference settings before making changes. Try loading again."
      return
    }
    guard settingsStore != nil, secretStore != nil else {
      errorMessage = "Inference backend settings are unavailable in this build."
      return
    }

    let needsDownload = needsLocalModelDownload
    if needsDownload {
      guard localModelInstaller != nil else {
        errorMessage = "Local model download is unavailable in this build."
        return
      }
      if mlxModelID.isEmpty { mlxModelID = Self.recommendedLocalModelID }
      if mlxDisplayName.isEmpty { mlxDisplayName = Self.recommendedLocalModelName }
    }

    let settings: HexInferenceBackendSettings
    do {
      settings = try makeSettings(requiresLocalDirectory: !needsDownload)
    } catch let error as HexInferenceBackendSettingsError {
      errorMessage = Self.message(for: error)
      return
    } catch is MLXLocalInferenceProviderError {
      errorMessage = "The local model folder could not be verified."
      return
    } catch {
      errorMessage = "Check the backend values before saving."
      return
    }

    let normalizedAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if selectedBackend == .openAIResponses {
      switch openAIAuthenticationMethod {
      case .apiKey:
        guard hasStoredOpenAIAPIKey || !normalizedAPIKey.isEmpty else {
          errorMessage = "Enter an OpenAI API key before saving."
          return
        }
      case .chatGPT:
        guard chatGPTAccountStatus == .signedIn else {
          errorMessage = "Sign in with ChatGPT before saving subscription inference."
          return
        }
      }
    }

    isSaving = true
    let operationID = UUID()
    saveOperationID = operationID
    saveTask = Task { [weak self] in
      guard let self else { return false }
      return await persist(
        settings, apiKey: normalizedAPIKey, needsDownload: needsDownload, operationID: operationID)
    }
  }

  func saveAndWait() async -> Bool {
    if !isSaving { save() }
    guard let saveTask else { return false }
    return await withTaskCancellationHandler {
      await saveTask.value
    } onCancel: {
      saveTask.cancel()
    }
  }

  func cancelSave() { saveTask?.cancel() }

  private func persist(
    _ snapshot: HexInferenceBackendSettings, apiKey: String,
    needsDownload: Bool, operationID: UUID
  ) async -> Bool {
    defer {
      isSaving = false
      isInstallingLocalModel = false
      saveOperationID = nil
    }
    guard let settingsStore, let secretStore else { return false }
    var didPersist = false
    var didPersistCredential = false
    do {
      try Task.checkCancellation()
      var settings = snapshot
      if needsDownload, let localModelInstaller {
        isInstallingLocalModel = true
        localModelDownloadProgress = 0
        statusMessage = "Downloading the local model…"
        let directory = try await localModelInstaller.install(modelID: snapshot.mlx.modelID) {
          [weak self] fraction in
          Task { @MainActor in
            guard let self, self.saveOperationID == operationID, fraction.isFinite else { return }
            self.localModelDownloadProgress = min(1, max(0, fraction))
          }
        }
        try Task.checkCancellation()
        settings = try settingsByValidatingLocalModel(snapshot, directory: directory)
        if mlxModelID == snapshot.mlx.modelID { mlxDirectory = directory }
        localModelDownloadProgress = 1
        isInstallingLocalModel = false
      }
      try Task.checkCancellation()
      if settings.selectedBackend == .openAIResponses,
        settings.openAI.authenticationMethod == .apiKey, !apiKey.isEmpty
      {
        try await secretStore.save(apiKey, for: .openAIAPIKey)
        didPersistCredential = true
        hasStoredOpenAIAPIKey = true
      }
      try Task.checkCancellation()
      try await settingsStore.save(settings)
      persistedSettings = settings
      didPersist = true
      try Task.checkCancellation()
      hasStoredOpenAIAPIKey = try await secretStore.exists(.openAIAPIKey)
      try Task.checkCancellation()
      if openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) == apiKey {
        openAIAPIKey = ""
      }
      try await configurationReloader?.reloadAfterConfigurationChange()
      try Task.checkCancellation()
      saveGeneration += 1
      statusMessage = "Inference backend settings saved."
      errorMessage = nil
      return true
    } catch is CancellationError {
      if didPersist {
        statusMessage = "Settings were saved, but applying them was cancelled. Save again to retry."
      } else if didPersistCredential {
        statusMessage =
          "Setup cancelled after the API key was saved to Keychain. Backend settings were not saved. Save again to finish setup."
      } else {
        statusMessage = "Setup cancelled. Your previous saved settings are unchanged."
      }
      errorMessage = nil
    } catch {
      statusMessage = nil
      if didPersist {
        errorMessage =
          "Settings were saved, but could not be applied to Hex Agent. Save again to retry."
      } else if didPersistCredential {
        errorMessage =
          "The API key was saved to Keychain, but backend settings could not be saved. Save again to finish setup."
      } else if isInstallingLocalModel {
        errorMessage =
          "Hex could not download or verify the local model. Check your connection and free space, then try again."
      } else {
        errorMessage =
          "Inference backend settings could not be saved. Check the values and try again."
      }
    }
    localModelDownloadProgress = nil
    return false
  }

  private func settingsByValidatingLocalModel(
    _ settings: HexInferenceBackendSettings, directory: URL
  ) throws -> HexInferenceBackendSettings {
    let local = settings.mlx
    _ = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: local.modelID), displayName: local.displayName,
      directory: directory, contextWindow: local.contextWindow,
      maximumOutputTokens: local.maximumOutputTokens,
      supportsToolCalling: local.supportsToolCalling,
      supportsParallelToolCalling: local.supportsParallelToolCalling)
    return try HexInferenceBackendSettings(
      selectedBackend: settings.selectedBackend, openAI: settings.openAI,
      mlx: HexMLXBackendSettings(
        modelID: local.modelID, displayName: local.displayName, directory: directory,
        contextWindow: local.contextWindow, maximumOutputTokens: local.maximumOutputTokens,
        supportsToolCalling: local.supportsToolCalling,
        supportsParallelToolCalling: local.supportsParallelToolCalling),
      llamaCpp: settings.llamaCpp)
  }

  private func apply(_ settings: HexInferenceBackendSettings) {
    selectedBackend = settings.selectedBackend
    openAIAuthenticationMethod = settings.openAI.authenticationMethod
    openAIModelID = settings.openAI.modelID
    mlxModelID = settings.mlx.modelID
    mlxDisplayName = settings.mlx.displayName
    mlxDirectory = settings.mlx.directory
    mlxContextWindow = settings.mlx.contextWindow.map(String.init) ?? ""
    mlxMaximumOutputTokens = String(settings.mlx.maximumOutputTokens)
    mlxSupportsToolCalling = settings.mlx.supportsToolCalling
    mlxSupportsParallelToolCalling = settings.mlx.supportsParallelToolCalling
    llamaModelID = settings.llamaCpp.modelID
    llamaDisplayName = settings.llamaCpp.displayName
    llamaEndpoint = settings.llamaCpp.endpoint?.absoluteString ?? ""
    llamaContextWindow = settings.llamaCpp.contextWindow.map(String.init) ?? ""
    llamaMaximumOutputTokens = String(settings.llamaCpp.maximumOutputTokens)
    llamaSupportsToolCalling = settings.llamaCpp.supportsToolCalling
    llamaSupportsParallelToolCalling = settings.llamaCpp.supportsParallelToolCalling
  }

  private func makeSettings(requiresLocalDirectory: Bool = true) throws
    -> HexInferenceBackendSettings
  {
    let openAI: HexOpenAIBackendSettings
    if selectedBackend == .openAIResponses {
      openAI = try HexOpenAIBackendSettings(
        modelID: openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines),
        authenticationMethod: openAIAuthenticationMethod)
    } else {
      openAI =
        try persistedSettings?.openAI
        ?? HexOpenAIBackendSettings(
          modelID: HexInferenceBackendSettings.defaultOpenAIModelID,
          authenticationMethod: .chatGPT)
    }
    if selectedBackend == .openAIResponses {
      return try HexInferenceBackendSettings(
        selectedBackend: selectedBackend, openAI: openAI,
        mlx: persistedSettings?.mlx ?? HexMLXBackendSettings(),
        llamaCpp: persistedSettings?.llamaCpp ?? HexLlamaCppBackendSettings())
    }
    if selectedBackend == .llamaCppLocal {
      let maximumOutputTokens = try Self.parsePositiveInteger(llamaMaximumOutputTokens)
      let contextWindow = try Self.parseOptionalPositiveInteger(llamaContextWindow)
      guard
        let endpoint = URL(
          string: llamaEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      else {
        throw HexInferenceBackendSettingsError.invalidLlamaEndpoint
      }
      let llama = try HexLlamaCppBackendSettings(
        modelID: llamaModelID.trimmingCharacters(in: .whitespacesAndNewlines),
        displayName: llamaDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
        endpoint: endpoint,
        contextWindow: contextWindow,
        maximumOutputTokens: maximumOutputTokens,
        supportsToolCalling: llamaSupportsToolCalling,
        supportsParallelToolCalling: llamaSupportsParallelToolCalling
      )
      guard llama.isConfigured else {
        throw HexInferenceBackendSettingsError.invalidLlamaEndpoint
      }
      return try HexInferenceBackendSettings(
        selectedBackend: selectedBackend,
        openAI: openAI,
        mlx: persistedSettings?.mlx ?? HexMLXBackendSettings(),
        llamaCpp: llama
      )
    }
    let maximumOutputTokens = try Self.parsePositiveInteger(mlxMaximumOutputTokens)
    let contextWindow = try Self.parseOptionalPositiveInteger(mlxContextWindow)
    var mlx = try HexMLXBackendSettings(
      modelID: mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines),
      displayName: mlxDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
      directory: mlxDirectory,
      contextWindow: contextWindow,
      maximumOutputTokens: maximumOutputTokens,
      supportsToolCalling: mlxSupportsToolCalling,
      supportsParallelToolCalling: mlxSupportsParallelToolCalling
    )
    if mlx.isConfigured {
      guard let directory = mlx.directory else {
        throw HexInferenceBackendSettingsError.invalidMLXDirectory
      }
      let validatedModel = try MLXLocalModelConfiguration(
        modelID: ModelID(rawValue: mlx.modelID),
        displayName: mlx.displayName,
        directory: directory,
        contextWindow: mlx.contextWindow,
        maximumOutputTokens: mlx.maximumOutputTokens,
        supportsToolCalling: mlx.supportsToolCalling,
        supportsParallelToolCalling: mlx.supportsParallelToolCalling
      )
      mlx = try HexMLXBackendSettings(
        modelID: validatedModel.modelID.rawValue,
        displayName: validatedModel.displayName,
        directory: validatedModel.directory,
        contextWindow: validatedModel.contextWindow,
        maximumOutputTokens: validatedModel.maximumOutputTokens,
        supportsToolCalling: validatedModel.supportsToolCalling,
        supportsParallelToolCalling: validatedModel.supportsParallelToolCalling
      )
    }
    guard !requiresLocalDirectory || selectedBackend != .mlxLocal || mlx.isConfigured else {
      throw HexInferenceBackendSettingsError.invalidMLXDirectory
    }
    return try HexInferenceBackendSettings(
      selectedBackend: selectedBackend,
      openAI: openAI,
      mlx: mlx,
      llamaCpp: persistedSettings?.llamaCpp ?? HexLlamaCppBackendSettings()
    )
  }

  private func updateCredentialStatusMessage() {
    guard selectedBackend == .openAIResponses else {
      statusMessage = nil
      return
    }
    switch openAIAuthenticationMethod {
    case .apiKey:
      statusMessage =
        hasStoredOpenAIAPIKey
        ? "An OpenAI API key is stored in Keychain."
        : "No OpenAI API key is stored."
    case .chatGPT:
      statusMessage = chatGPTAccountStatus.detail
    }
  }

  private static func parsePositiveInteger(_ value: String) throws -> Int {
    guard let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 else {
      throw HexInferenceBackendSettingsError.invalidMLXOutputTokens
    }
    return number
  }

  private static func parseOptionalPositiveInteger(_ value: String) throws -> Int? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    guard let number = Int(normalized), number > 0 else {
      throw HexInferenceBackendSettingsError.invalidMLXContextWindow
    }
    return number
  }

  private static func isExistingDirectory(_ url: URL) -> Bool {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func message(for error: HexInferenceBackendSettingsError) -> String {
    switch error {
    case .invalidOpenAIModelID:
      "Enter an OpenAI model identifier."
    case .invalidMLXModelID:
      "Enter a local model identifier."
    case .invalidMLXDisplayName:
      "Enter a name for the local model."
    case .invalidMLXDirectory:
      "Choose an existing local model folder."
    case .invalidMLXOutputTokens:
      "Enter a positive output limit for the local model."
    case .invalidMLXContextWindow:
      "Enter a positive context limit at least as large as the output limit."
    case .invalidLlamaModelID:
      "Enter a local GGUF model identifier."
    case .invalidLlamaDisplayName:
      "Enter a name for the local GGUF model."
    case .invalidLlamaEndpoint:
      "Enter the local llama.cpp server URL, such as http://127.0.0.1:8080."
    case .invalidLlamaOutputTokens:
      "Enter a positive output limit for the local GGUF model."
    case .invalidLlamaContextWindow:
      "Enter a positive GGUF context limit at least as large as the output limit."
    case .unsupportedSchemaVersion:
      "The saved inference-backend settings use an unsupported version."
    }
  }

  private static func messageForChatGPTAccountAction(_ error: any Error) -> String {
    if let error = error as? ChatGPTCodexOAuthError {
      return error.localizedDescription
    }
    return "The ChatGPT account action could not be completed. Check your connection and try again."
  }
}
