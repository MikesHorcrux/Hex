import Foundation
import HexCore

public struct LlamaCppLocalInferenceProviderBuilder: Sendable {
  public static let defaultProviderID = ProviderID(rawValue: "llama.cpp.local")
  public static let defaultProviderDisplayName = "Local GGUF (Prism)"

  public init() {}

  public func configuration(
    for settings: HexLlamaCppBackendSettings
  ) throws -> LlamaCppLocalProviderConfiguration {
    guard settings.isConfigured, let endpoint = settings.endpoint else {
      throw LlamaCppLocalInferenceProviderError.invalidModelConfiguration
    }
    let model = try LlamaCppLocalModelConfiguration(
      modelID: ModelID(rawValue: settings.modelID),
      displayName: settings.displayName,
      contextWindow: settings.contextWindow,
      maximumOutputTokens: settings.maximumOutputTokens,
      supportsToolCalling: settings.supportsToolCalling,
      supportsParallelToolCalling: settings.supportsParallelToolCalling
    )
    return try LlamaCppLocalProviderConfiguration(
      providerID: Self.defaultProviderID,
      displayName: Self.defaultProviderDisplayName,
      endpoint: endpoint,
      models: [model]
    )
  }

  public func makeInferenceProvider(
    for settings: HexLlamaCppBackendSettings
  ) throws -> any InferenceProvider {
    try LlamaCppLocalInferenceProvider(configuration: configuration(for: settings))
  }
}
