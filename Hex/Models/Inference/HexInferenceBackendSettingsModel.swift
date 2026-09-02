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
  var selectedBackend: HexInferenceBackendKind
  var openAIAuthenticationMethod: HexOpenAIAuthenticationMethod
  var openAIModelID: String
  var openAIAPIKey = ""

  var mlxModelID: String
  var mlxDisplayName: String
  var mlxDirectory: URL?
  var mlxContextWindow = ""
  var mlxMaximumOutputTokens = "2048"
  var mlxSupportsToolCalling = false
  var mlxSupportsParallelToolCalling = false

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredOpenAIAPIKey = false
  private(set) var chatGPTAccountStatus = ChatGPTCodexOAuthAccountStatus.signedOut
  private(set) var chatGPTLoginChallenge: ChatGPTCodexDeviceAuthorizationChallenge?
  private(set) var isChatGPTLoginInProgress = false
  private(set) var isChatGPTLogoutInProgress = false
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var saveGeneration = 0

  private let settingsStore: (any HexInferenceBackendSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private let chatGPTAuthorizationManager: (any ChatGPTCodexOAuthManaging)?
  private var hasLoaded = false
  private var accountActionGeneration = 0
  @ObservationIgnored private var accountActionTask: Task<Void, Never>?

  init(
    settingsStore: (any HexInferenceBackendSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    chatGPTAuthorizationManager: (any ChatGPTCodexOAuthManaging)? = nil
  ) {
    selectedBackend = .openAIResponses
    openAIAuthenticationMethod = .chatGPT
    openAIModelID = HexInferenceBackendSettings.defaultOpenAIModelID
    mlxModelID = ""
    mlxDisplayName = ""
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.chatGPTAuthorizationManager = chatGPTAuthorizationManager
  }

  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && settingsStore != nil && secretStore != nil
  }

  var effectiveModelID: String {
    switch selectedBackend {
    case .openAIResponses:
      openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    case .mlxLocal:
      mlxModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  var mlxDirectoryDisplayName: String {
    mlxDirectory?.path ?? "Choose an existing model folder"
  }

  func load() async {
    guard !hasLoaded, !isLoading else { return }
    hasLoaded = true
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
      }
      hasStoredOpenAIAPIKey = try await secretStore.exists(.openAIAPIKey)
      if let chatGPTAuthorizationManager {
        chatGPTAccountStatus = await chatGPTAuthorizationManager.accountStatus()
      } else {
        chatGPTAccountStatus = .unavailable
      }
      errorMessage = nil
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
      errorMessage = "Choose an existing local folder for the MLX model."
      statusMessage = nil
      return
    }
    mlxDirectory = url.standardizedFileURL
    errorMessage = nil
    statusMessage = "The MLX directory will be validated when you save. Hex will not download it."
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
    guard !isSaving else { return }
    errorMessage = nil
    statusMessage = nil
    guard let settingsStore, let secretStore else {
      errorMessage = "Inference backend settings are unavailable in this build."
      return
    }

    let settings: HexInferenceBackendSettings
    do {
      settings = try makeSettings()
    } catch let error as HexInferenceBackendSettingsError {
      errorMessage = Self.message(for: error)
      return
    } catch is MLXLocalInferenceProviderError {
      errorMessage = "The MLX model directory is not a safe, existing local model directory."
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
    Task { [weak self] in
      guard let self else { return }
      do {
        try await settingsStore.save(settings)
        if settings.selectedBackend == .openAIResponses,
          settings.openAI.authenticationMethod == .apiKey,
          !normalizedAPIKey.isEmpty
        {
          try await secretStore.save(normalizedAPIKey, for: .openAIAPIKey)
        }
        hasStoredOpenAIAPIKey = try await secretStore.exists(.openAIAPIKey)
        openAIAPIKey = ""
        saveGeneration += 1
        statusMessage = "Inference backend settings saved."
        errorMessage = nil
        isSaving = false
      } catch is CancellationError {
        isSaving = false
      } catch {
        errorMessage =
          "Inference backend settings could not be saved. Check the values and try again."
        statusMessage = nil
        isSaving = false
      }
    }
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
  }

  private func makeSettings() throws -> HexInferenceBackendSettings {
    let openAI = try HexOpenAIBackendSettings(
      modelID: openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines),
      authenticationMethod: openAIAuthenticationMethod
    )
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
    guard selectedBackend != .mlxLocal || mlx.isConfigured else {
      throw HexInferenceBackendSettingsError.invalidMLXDirectory
    }
    return try HexInferenceBackendSettings(
      selectedBackend: selectedBackend,
      openAI: openAI,
      mlx: mlx
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
      "Enter an MLX model identifier."
    case .invalidMLXDisplayName:
      "Enter a display name for the MLX model."
    case .invalidMLXDirectory:
      "Choose an existing local MLX model directory."
    case .invalidMLXOutputTokens:
      "Enter a positive MLX output-token limit."
    case .invalidMLXContextWindow:
      "Enter a positive MLX context window at least as large as the output limit."
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
