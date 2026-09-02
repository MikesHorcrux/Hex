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

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredOpenAIAPIKey = false
  private(set) var codexAccountStatus = CodexCompatibilityAccountStatus.notConfigured
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
}
