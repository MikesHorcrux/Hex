import Foundation
import HexCore
import HexPersistence
import HexProviders

nonisolated enum HexInProcessInferenceResolution: Sendable {
  case openAI(
    settings: HexOpenAIBackendSettings,
    authorizationProvider: any OpenAIResponsesAuthorizationProvider
  )
}
