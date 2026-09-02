import Foundation
import HexCore
import HexPersistence
import HexProviders

/// Resolves the in-process inference boundary from the same protected settings and secret stores
/// used by the resident route. The resolver has no provider fallback: a selected backend without
/// an app-linked adapter is an actionable failure.
nonisolated struct HexInProcessInferenceConfigurationResolver: Sendable {
  enum Resolution: Sendable {
    case openAI(
      modelID: String,
      credentialProvider: any OpenAICredentialProvider
    )
  }

  enum ResolutionError: Error, Equatable, LocalizedError, Sendable {
    case settingsUnavailable
    case credentialsUnavailable
    case unsupportedBackend(HexInferenceBackendKind)

    var errorDescription: String? {
      switch self {
      case .settingsUnavailable:
        "Hex could not load inference-backend settings. Open Inference settings and choose a supported configuration."
      case .credentialsUnavailable:
        "OpenAI Responses is selected, but no OpenAI API key is available in Keychain. Add one in Inference settings."
      case .unsupportedBackend(.mlxLocal):
        "Local MLX is selected, but its in-process inference adapter is not linked in this build. Link and configure the MLX adapter before selecting it."
      case .unsupportedBackend(.codexCompatibility):
        "Codex compatibility is selected, but its in-process app-server inference adapter is not linked in this build. Configure an adapter before selecting it; a ChatGPT subscription is never used as raw inference."
      case .unsupportedBackend(.openAIResponses):
        "OpenAI Responses is selected, but its in-process inference adapter is unavailable. Check the Hex build configuration."
      }
    }
  }

  private static let defaultOpenAIModelID = "gpt-5.2"

  private let settingsStore: (any HexInferenceBackendSettingsStore)?
  private let secretStore: (any HexSecretStore)?
  private let defaultModelID: String

  init(
    settingsStore: (any HexInferenceBackendSettingsStore)?,
    secretStore: (any HexSecretStore)?,
    defaultOpenAIModelID: String? = nil
  ) {
    self.settingsStore = settingsStore
    self.secretStore = secretStore
    defaultModelID = defaultOpenAIModelID ?? Self.defaultOpenAIModelID
  }

  func resolve() async throws -> Resolution {
    guard let settingsStore else {
      throw ResolutionError.settingsUnavailable
    }

    let settings: HexInferenceBackendSettings
    do {
      settings =
        try await settingsStore.load()
        ?? HexInferenceBackendSettings(openAIModelID: defaultModelID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ResolutionError.settingsUnavailable
    }

    guard settings.selectedBackend == .openAIResponses else {
      throw ResolutionError.unsupportedBackend(settings.selectedBackend)
    }
    guard let secretStore else {
      throw ResolutionError.credentialsUnavailable
    }

    do {
      guard try await secretStore.exists(.openAIAPIKey) else {
        throw ResolutionError.credentialsUnavailable
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ResolutionError {
      throw error
    } catch {
      throw ResolutionError.credentialsUnavailable
    }

    return .openAI(
      modelID: settings.openAI.modelID,
      credentialProvider: HexSecretStoreOpenAICredentialProvider(store: secretStore)
    )
  }
}
