import Foundation
import HexCore
import Observation

@MainActor
@Observable
final class HexResidentSetupModel {
  var apiKey = ""
  var modelID: String
  var workspaceRoot: URL?

  private(set) var isLoading = false
  private(set) var isSaving = false
  private(set) var hasStoredAPIKey = false
  private(set) var statusMessage: String?
  private(set) var errorMessage: String?
  private(set) var saveGeneration = 0

  private let settingsStore: (any HexResidentRuntimeSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private var hasLoaded = false

  init(
    initialModelID: String = "",
    settingsStore: (any HexResidentRuntimeSettingsStore)? = nil,
    secretStore: (any HexSecretStore)? = nil
  ) {
    modelID = initialModelID
    self.settingsStore = settingsStore
    self.secretStore = secretStore
  }

  var workspaceDisplayName: String {
    workspaceRoot?.path ?? "Choose a workspace folder"
  }

  var canSave: Bool {
    hasLoaded && !isLoading && !isSaving && settingsStore != nil && secretStore != nil
  }

  func load() async {
    guard !hasLoaded, !isLoading else { return }
    hasLoaded = true
    isLoading = true
    defer { isLoading = false }

    guard let settingsStore, let secretStore else {
      statusMessage = nil
      errorMessage = "Resident setup is unavailable in this build."
      return
    }

    do {
      if let settings = try await settingsStore.load() {
        modelID = settings.modelID
        workspaceRoot = settings.workspaceRoot
      }
      hasStoredAPIKey = try await secretStore.exists(.openAIAPIKey)
      errorMessage = nil
      statusMessage =
        hasStoredAPIKey
        ? "A stored OpenAI API key is ready."
        : "Add an OpenAI API key to enable the resident gateway."
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
    guard hasStoredAPIKey || !normalizedAPIKey.isEmpty else {
      errorMessage = "Enter an OpenAI API key before saving for the first time."
      return
    }
    guard let settingsStore, let secretStore else {
      errorMessage = "Resident setup is unavailable in this build."
      return
    }

    let settings: HexResidentRuntimeSettings
    do {
      settings = try HexResidentRuntimeSettings(
        modelID: normalizedModelID,
        workspaceRoot: workspaceRoot
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
