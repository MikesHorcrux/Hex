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
      settings: HexOpenAIBackendSettings,
      authorizationProvider: any OpenAIResponsesAuthorizationProvider
    )
  }

  enum ResolutionError: Error, Equatable, LocalizedError, Sendable {
    case settingsUnavailable
    case credentialsUnavailable(HexOpenAIAuthenticationMethod)
    case unsupportedBackend(HexInferenceBackendKind)

    var errorDescription: String? {
      switch self {
      case .settingsUnavailable:
        "Hex could not load inference-backend settings. Open Inference settings and choose a supported configuration."
      case .credentialsUnavailable(.apiKey):
        "OpenAI is selected, but no API key is available in Keychain. Add one in Inference settings."
      case .credentialsUnavailable(.chatGPT):
        "OpenAI is selected, but Hex is not signed in with ChatGPT. Sign in under Inference settings."
      case .unsupportedBackend(.mlxLocal):
        "Local MLX is selected, but its in-process inference adapter is not linked in this build. Link and configure the MLX adapter before selecting it."
      case .unsupportedBackend(.openAIResponses):
        "OpenAI is selected, but its in-process inference adapter is unavailable. Check the Hex build configuration."
      }
    }
  }

  private static let defaultOpenAIModelID = HexInferenceBackendSettings.defaultOpenAIModelID

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
      throw ResolutionError.credentialsUnavailable(settings.openAI.authenticationMethod)
    }

    let requiredSecret: HexSecretKey =
      settings.openAI.authenticationMethod == .chatGPT
      ? .openAIChatGPTOAuth
      : .openAIAPIKey
    do {
      guard try await secretStore.exists(requiredSecret) else {
        throw ResolutionError.credentialsUnavailable(settings.openAI.authenticationMethod)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ResolutionError {
      throw error
    } catch {
      throw ResolutionError.credentialsUnavailable(settings.openAI.authenticationMethod)
    }

    let authorizationProvider: any OpenAIResponsesAuthorizationProvider =
      settings.openAI.authenticationMethod == .chatGPT
      ? ChatGPTCodexOAuthSession(secretStore: secretStore)
      : HexSecretStoreOpenAICredentialProvider(store: secretStore)
    return .openAI(
      settings: settings.openAI,
      authorizationProvider: authorizationProvider
    )
  }
}
