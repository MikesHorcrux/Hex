import Foundation
import HexCore
import HexProviders
import Observation

/// Main-actor settings model for selecting and validating Hex inference backends.
///
/// The API-key field is a transient edit buffer. It is sent directly to the injected secret store
/// during save and is cleared immediately after a successful save; it is never part of the JSON
/// settings value or a `UserDefaults` value.
@MainActor
@Observable
final class HexInferenceBackendSettingsModel {
  var selectedBackend: HexInferenceBackendKind
  var openAIModelID: String
  var openAIAPIKey = ""

  var mlxModelID: String
  var mlxDisplayName: String
  var mlxDirectory: URL?
  var mlxContextWindow = ""
  var mlxMaximumOutputTokens = "2048"
  var mlxSupportsToolCalling = false
  var mlxSupportsParallelToolCalling = false

  var codexExecutableURL: URL?
  var codexWorkingDirectoryURL: URL?
  var codexLoginMode: CodexChatGPTLoginMode = .browser

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredOpenAIAPIKey = false
  private(set) var codexAccountStatus = CodexCompatibilityAccountStatus.notConfigured
  private(set) var codexLoginChallenge: CodexCompatibilityLoginChallenge?
  private(set) var isCodexLoginInProgress = false
  private(set) var isCodexLogoutInProgress = false
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var saveGeneration = 0

  private let settingsStore: (any HexInferenceBackendSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private let makeCodexStatusProvider:
    (
      @Sendable (HexCodexCompatibilitySettings) throws
        -> any CodexCompatibilityAccountStatusProviding
    )?
  private var hasLoaded = false
  private var statusRequestGeneration = 0
  private var codexAccountActionGeneration = 0
  private var activeCodexAccountManager: (any CodexCompatibilityAccountManaging)?

  init(
    settingsStore: (any HexInferenceBackendSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil,
    makeCodexStatusProvider:
      (
        @Sendable (HexCodexCompatibilitySettings) throws
          -> any CodexCompatibilityAccountStatusProviding
      )? = nil
  ) {
    selectedBackend = .openAIResponses
    openAIModelID = "gpt-5.2"
    mlxModelID = ""
    mlxDisplayName = ""
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    self.makeCodexStatusProvider = makeCodexStatusProvider
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
    case .codexCompatibility:
      "codex-compatibility"
    }
  }

  var mlxDirectoryDisplayName: String {
    mlxDirectory?.path ?? "Choose an existing model folder"
  }

  var codexExecutableDisplayName: String {
    codexExecutableURL?.path ?? "Choose an existing Codex executable"
  }

  var codexWorkingDirectoryDisplayName: String {
    codexWorkingDirectoryURL?.path ?? "Use the current user home folder"
  }

  func load() async {
    guard !hasLoaded, !isLoading else { return }
    hasLoaded = true
    isLoading = true
    defer { isLoading = false }

    guard let settingsStore, let secretStore else {
      errorMessage = "Inference backend settings are unavailable in this build."
      codexAccountStatus = .unavailable
      return
    }

    do {
      if let settings = try await settingsStore.load() {
        apply(settings)
      }
      hasStoredOpenAIAPIKey = try await secretStore.exists(.openAIAPIKey)
      errorMessage = nil
      statusMessage =
        hasStoredOpenAIAPIKey
        ? "An OpenAI API key is stored in Keychain."
        : "No OpenAI API key is stored."
    } catch {
      errorMessage =
        "Inference backend settings could not be loaded. Check the setup and try again."
      statusMessage = nil
      codexAccountStatus = .unavailable
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

  func chooseCodexExecutable(_ url: URL) {
    guard Self.isExistingExecutable(url) else {
      errorMessage = "Choose an existing executable file for Codex app-server."
      statusMessage = nil
      return
    }
    codexExecutableURL = url.standardizedFileURL
    errorMessage = nil
    statusMessage = "Hex will use this existing executable; it will not install or download Codex."
  }

  func chooseCodexWorkingDirectory(_ url: URL) {
    guard Self.isExistingDirectory(url) else {
      errorMessage = "Choose an existing local working directory for Codex."
      statusMessage = nil
      return
    }
    codexWorkingDirectoryURL = url.standardizedFileURL
    errorMessage = nil
    statusMessage = nil
  }

  func errorMessageForFileSelectionFailure() {
    errorMessage = "The selected file or folder could not be used."
    statusMessage = nil
  }

  func clearCodexExecutable() {
    codexExecutableURL = nil
    codexAccountStatus = .notConfigured
    statusMessage = nil
  }

  func refreshCodexAccountStatus() {
    statusRequestGeneration += 1
    let requestGeneration = statusRequestGeneration
    guard let executableURL = codexExecutableURL else {
      codexAccountStatus = .notConfigured
      return
    }
    guard let makeCodexStatusProvider else {
      codexAccountStatus = .unavailable
      return
    }
    let codexSettings: HexCodexCompatibilitySettings
    do {
      codexSettings = try HexCodexCompatibilitySettings(
        executableURL: executableURL,
        workingDirectoryURL: codexWorkingDirectoryURL
      )
    } catch {
      codexAccountStatus = .unavailable
      return
    }

    codexAccountStatus = .checking
    Task { [weak self] in
      let status: CodexCompatibilityAccountStatus
      do {
        let provider = try makeCodexStatusProvider(codexSettings)
        status = await provider.status()
      } catch {
        status = .unavailable
      }
      guard let self, self.statusRequestGeneration == requestGeneration else { return }
      self.codexAccountStatus = status
    }
  }

  func startCodexLogin() {
    guard !isCodexLoginInProgress, !isCodexLogoutInProgress,
      codexLoginChallenge == nil
    else { return }

    let manager: any CodexCompatibilityAccountManaging
    do {
      manager = try makeCodexAccountManager()
    } catch {
      errorMessage = Self.messageForCodexAccountAction(error)
      statusMessage = nil
      return
    }

    codexAccountActionGeneration += 1
    let actionGeneration = codexAccountActionGeneration
    let mode = codexLoginMode
    activeCodexAccountManager = manager
    isCodexLoginInProgress = true
    errorMessage = nil
    statusMessage = "Starting Codex sign-in…"

    Task { [weak self] in
      do {
        let challenge = try await manager.startLogin(mode)
        guard let self, self.codexAccountActionGeneration == actionGeneration else {
          await manager.shutdown()
          return
        }
        self.codexLoginChallenge = challenge
        self.isCodexLoginInProgress = false
        self.statusMessage = Self.messageForCodexLoginChallenge(challenge)
      } catch {
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.isCodexLoginInProgress = false
        if error is CancellationError { return }
        self.statusMessage = nil
        self.errorMessage = Self.messageForCodexAccountAction(error)
      }
    }
  }

  func completeCodexLogin() {
    guard !isCodexLoginInProgress, !isCodexLogoutInProgress,
      let challenge = codexLoginChallenge,
      let manager = activeCodexAccountManager
    else { return }

    codexAccountActionGeneration += 1
    let actionGeneration = codexAccountActionGeneration
    let loginID = challenge.loginID
    isCodexLoginInProgress = true
    errorMessage = nil
    statusMessage = "Waiting for Codex to confirm sign-in…"

    Task { [weak self] in
      do {
        try await manager.completeLogin(loginID)
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.codexLoginChallenge = nil
        self.isCodexLoginInProgress = false
        self.errorMessage = nil
        self.statusMessage =
          "Codex sign-in completed. Refresh to read the redacted account status."
      } catch {
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.codexLoginChallenge = nil
        self.isCodexLoginInProgress = false
        if error is CancellationError { return }
        self.statusMessage = nil
        self.errorMessage = Self.messageForCodexAccountAction(error)
      }
    }
  }

  func cancelCodexLogin() {
    guard !isCodexLogoutInProgress, let manager = activeCodexAccountManager else { return }

    codexAccountActionGeneration += 1
    let actionGeneration = codexAccountActionGeneration
    let loginID = codexLoginChallenge?.loginID
    isCodexLoginInProgress = true
    errorMessage = nil
    statusMessage = "Cancelling Codex sign-in…"

    Task { [weak self] in
      do {
        if let loginID {
          let status = try await manager.cancelLogin(loginID)
          guard status == .cancelled else {
            throw CodexCompatibilityAccountManagerError.loginNotFound
          }
        }
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.codexLoginChallenge = nil
        self.isCodexLoginInProgress = false
        self.errorMessage = nil
        self.statusMessage = "Codex sign-in cancelled."
      } catch {
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.codexLoginChallenge = nil
        self.isCodexLoginInProgress = false
        if error is CancellationError { return }
        self.statusMessage = nil
        self.errorMessage = Self.messageForCodexAccountAction(error)
      }
    }
  }

  func logoutCodexAccount() {
    guard !isCodexLoginInProgress, !isCodexLogoutInProgress,
      codexLoginChallenge == nil
    else { return }

    let manager: any CodexCompatibilityAccountManaging
    do {
      manager = try makeCodexAccountManager()
    } catch {
      errorMessage = Self.messageForCodexAccountAction(error)
      statusMessage = nil
      return
    }

    codexAccountActionGeneration += 1
    let actionGeneration = codexAccountActionGeneration
    activeCodexAccountManager = manager
    isCodexLogoutInProgress = true
    errorMessage = nil
    statusMessage = "Signing out of the Codex account…"

    Task { [weak self] in
      do {
        try await manager.logout()
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.isCodexLogoutInProgress = false
        self.codexAccountStatus = .signedOut
        self.errorMessage = nil
        self.statusMessage = "Codex signed out."
      } catch {
        await manager.shutdown()
        guard let self, self.codexAccountActionGeneration == actionGeneration else { return }
        self.activeCodexAccountManager = nil
        self.isCodexLogoutInProgress = false
        if error is CancellationError { return }
        self.statusMessage = nil
        self.errorMessage = Self.messageForCodexAccountAction(error)
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
      guard hasStoredOpenAIAPIKey || !normalizedAPIKey.isEmpty else {
        errorMessage = "Enter an OpenAI API key before saving OpenAI Responses mode."
        return
      }
    }

    isSaving = true
    Task { [weak self] in
      guard let self else { return }
      do {
        // Keep the non-secret settings write separate from Keychain. A failed settings write must
        // not replace a credential that a currently-running gateway may still use.
        try await settingsStore.save(settings)
        if !normalizedAPIKey.isEmpty {
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
    openAIModelID = settings.openAI.modelID
    mlxModelID = settings.mlx.modelID
    mlxDisplayName = settings.mlx.displayName
    mlxDirectory = settings.mlx.directory
    mlxContextWindow = settings.mlx.contextWindow.map(String.init) ?? ""
    mlxMaximumOutputTokens = String(settings.mlx.maximumOutputTokens)
    mlxSupportsToolCalling = settings.mlx.supportsToolCalling
    mlxSupportsParallelToolCalling = settings.mlx.supportsParallelToolCalling
    codexExecutableURL = settings.codex.executableURL
    codexWorkingDirectoryURL = settings.codex.workingDirectoryURL
  }

  private func makeCodexAccountManager() throws -> any CodexCompatibilityAccountManaging {
    guard let makeCodexStatusProvider else {
      throw CodexCompatibilityAccountManagerError.unsupported
    }
    guard let executableURL = codexExecutableURL else {
      throw HexInferenceBackendSettingsError.invalidCodexExecutable
    }
    let codexSettings = try HexCodexCompatibilitySettings(
      executableURL: executableURL,
      workingDirectoryURL: codexWorkingDirectoryURL
    )
    let provider = try makeCodexStatusProvider(codexSettings)
    guard let manager = provider as? any CodexCompatibilityAccountManaging else {
      throw CodexCompatibilityAccountManagerError.unsupported
    }
    return manager
  }

  private func makeSettings() throws -> HexInferenceBackendSettings {
    let openAI = try HexOpenAIBackendSettings(
      modelID: openAIModelID.trimmingCharacters(in: .whitespacesAndNewlines))
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
    let codex = try HexCodexCompatibilitySettings(
      executableURL: codexExecutableURL,
      workingDirectoryURL: codexWorkingDirectoryURL
    )
    guard selectedBackend != .mlxLocal || mlx.isConfigured else {
      throw HexInferenceBackendSettingsError.invalidMLXDirectory
    }
    guard selectedBackend != .codexCompatibility || codex.isConfigured else {
      throw HexInferenceBackendSettingsError.invalidCodexExecutable
    }
    return try HexInferenceBackendSettings(
      selectedBackend: selectedBackend,
      openAI: openAI,
      mlx: mlx,
      codex: codex
    )
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

  private static func isExistingExecutable(_ url: URL) -> Bool {
    url.isFileURL && url.path.hasPrefix("/")
      && FileManager.default.isExecutableFile(atPath: url.path)
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
    case .invalidCodexExecutable:
      "Choose an existing Codex executable for compatibility mode."
    case .invalidCodexWorkingDirectory:
      "Choose an existing Codex working directory."
    case .unsupportedSchemaVersion:
      "The saved inference-backend settings use an unsupported version."
    }
  }

  private static func messageForCodexAccountAction(_ error: any Error) -> String {
    switch error {
    case CodexCompatibilityAccountManagerError.loginTimedOut:
      "Codex sign-in timed out. Start sign-in again."
    case CodexCompatibilityAccountManagerError.loginRejected:
      "Codex rejected sign-in. Check the Codex authorization page and try again."
    case CodexCompatibilityAccountManagerError.loginNotFound:
      "Codex could not find that sign-in flow. Start sign-in again."
    case CodexCompatibilityAccountManagerError.unsupported:
      "Codex account actions are unavailable in this compatibility provider."
    case CodexCompatibilityAccountManagerError.failed:
      "The Codex account action failed. Check the existing executable and try again."
    case HexInferenceBackendSettingsError.invalidCodexExecutable:
      "Choose an existing Codex executable before managing its account."
    case is CodexAccountClientError:
      "The Codex account action could not be completed. Check Codex and try again."
    default:
      "The Codex account action could not be completed. Check Codex and try again."
    }
  }

  private static func messageForCodexLoginChallenge(
    _ challenge: CodexCompatibilityLoginChallenge
  ) -> String {
    switch challenge {
    case .browser:
      "Open the Codex authorization page, then check for completion."
    case .deviceCode:
      "Open the Codex verification page, enter the code, then check for completion."
    }
  }
}
