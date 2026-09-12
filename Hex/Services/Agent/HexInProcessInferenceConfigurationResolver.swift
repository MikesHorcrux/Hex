import Foundation
import HexCore
import HexPersistence
import HexProviders

/// Resolves the in-process inference boundary from the same protected settings and secret stores
/// used by the resident route. The resolver has no provider fallback: a selected backend without
/// an app-linked adapter is an actionable failure.
nonisolated struct HexInProcessInferenceConfigurationResolver: Sendable {
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

  func resolve() async throws -> HexInProcessInferenceResolution {
    guard let settingsStore else {
      throw HexInProcessInferenceResolutionError.settingsUnavailable
    }

    let settings: HexInferenceBackendSettings
    do {
      settings =
        try await settingsStore.load()
        ?? HexInferenceBackendSettings(openAIModelID: defaultModelID)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw HexInProcessInferenceResolutionError.settingsUnavailable
    }

    guard settings.selectedBackend == .openAIResponses else {
      throw HexInProcessInferenceResolutionError.unsupportedBackend(
        settings.selectedBackend)
    }
    guard let secretStore else {
      throw HexInProcessInferenceResolutionError.credentialsUnavailable(
        settings.openAI.authenticationMethod)
    }

    let requiredSecret: HexSecretKey =
      settings.openAI.authenticationMethod == .chatGPT
      ? .openAIChatGPTOAuth
      : .openAIAPIKey
    do {
      guard try await secretStore.exists(requiredSecret) else {
        throw HexInProcessInferenceResolutionError.credentialsUnavailable(
          settings.openAI.authenticationMethod)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HexInProcessInferenceResolutionError {
      throw error
    } catch {
      throw HexInProcessInferenceResolutionError.credentialsUnavailable(
        settings.openAI.authenticationMethod)
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
