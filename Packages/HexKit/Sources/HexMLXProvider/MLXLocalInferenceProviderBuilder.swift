import HexCore
import HexProviders
import MLXLLM

/// Builds the concrete local MLX provider from persisted, validated backend settings.
///
/// Construction only validates and records the selected model. The MLX model is loaded lazily by
/// `MLXLocalInferenceProvider` when its first request is streamed. The loader and provider seams
/// keep this boundary testable without Metal work or model I/O.
public struct MLXLocalInferenceProviderBuilder: Sendable {
  public typealias EngineLoaderFactory = @Sendable () -> any MLXInferenceEngineLoader
  public typealias ProviderFactory =
    @Sendable (
      MLXLocalProviderConfiguration,
      any MLXInferenceEngineLoader
    ) -> MLXLocalInferenceProvider

  public static let defaultProviderID = ProviderID(rawValue: "mlx.local")
  public static let defaultProviderDisplayName = "Local MLX"

  private let makeEngineLoader: EngineLoaderFactory
  private let makeProvider: ProviderFactory

  /// Creates a production builder using the official MLX LLM model registry and factory.
  public init(
    makeEngineLoader: @escaping EngineLoaderFactory = {
      MLXSwiftInferenceEngineLoader(factory: LLMModelFactory.shared)
    },
    makeProvider: @escaping ProviderFactory = { configuration, engineLoader in
      MLXLocalInferenceProvider(
        configuration: configuration,
        engineLoader: engineLoader
      )
    }
  ) {
    self.makeEngineLoader = makeEngineLoader
    self.makeProvider = makeProvider
  }

  /// Creates a builder around an injected engine loader, useful for deterministic tests.
  public init(engineLoader: any MLXInferenceEngineLoader) {
    self.init(makeEngineLoader: { engineLoader })
  }

  /// Maps the selected settings into the provider configuration without loading the model.
  public func configuration(
    for settings: HexMLXBackendSettings
  ) throws -> MLXLocalProviderConfiguration {
    guard settings.isConfigured, let directory = settings.directory else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }

    let model = try MLXLocalModelConfiguration(
      modelID: ModelID(rawValue: settings.modelID),
      displayName: settings.displayName,
      directory: directory,
      contextWindow: settings.contextWindow,
      maximumOutputTokens: settings.maximumOutputTokens,
      supportsToolCalling: settings.supportsToolCalling,
      supportsParallelToolCalling: settings.supportsParallelToolCalling
    )
    return try MLXLocalProviderConfiguration(
      providerID: Self.defaultProviderID,
      displayName: Self.defaultProviderDisplayName,
      models: [model]
    )
  }

  /// Builds the concrete provider. Model loading remains deferred until `stream` is called.
  public func makeProvider(
    for settings: HexMLXBackendSettings
  ) throws -> MLXLocalInferenceProvider {
    let providerConfiguration = try configuration(for: settings)
    let engineLoader = makeEngineLoader()
    return makeProvider(providerConfiguration, engineLoader)
  }

  /// Builds the provider through the provider-neutral inference boundary.
  public func makeInferenceProvider(
    for settings: HexMLXBackendSettings
  ) throws -> any InferenceProvider {
    try makeProvider(for: settings)
  }
}
