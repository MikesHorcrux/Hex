import Foundation
import HexCore

public struct OpenAIResponsesConfiguration: Equatable, Sendable {
  /// The canonical OpenAI Platform Responses endpoint. Custom hosts and paths are rejected so an
  /// OpenAI API key cannot be redirected to a proxy or unrelated origin.
  public let endpoint: URL
  public let providerID: ProviderID
  public let displayName: String
  public let models: [ModelDescriptor]
  public let privacyMode: OpenAIResponsesPrivacyMode
  public let requestTimeout: TimeInterval
  public let requestReasoningSummaries: Bool
  public let maximumMessages: Int
  public let maximumTools: Int
  public let maximumIdentifierBytes: Int
  public let maximumInputValueBytes: Int
  public let maximumRequestBodyBytes: Int
  public let maximumSSELineBytes: Int
  public let maximumSSEEventBytes: Int
  public let maximumResponseBytes: Int
  public let maximumStreamEvents: Int
  public let maximumToolArgumentBytes: Int
  public let maximumOutputItems: Int
  public let maximumJSONDepth: Int
  public let maximumJSONNodes: Int
  public let maximumReplaySegments: Int
  public let maximumLocalStates: Int
  public let maximumLocalStateBytes: Int
  public let maximumLocalCacheBytes: Int

  public init(
    endpoint: URL? = nil,
    providerID: ProviderID = ProviderID(rawValue: "openai"),
    displayName: String = "OpenAI Responses API",
    models: [ModelDescriptor],
    privacyMode: OpenAIResponsesPrivacyMode = .serverManagedContinuation,
    requestTimeout: TimeInterval = 120,
    requestReasoningSummaries: Bool = true,
    maximumMessages: Int = 4_096,
    maximumTools: Int = 512,
    maximumIdentifierBytes: Int = 512,
    maximumInputValueBytes: Int = 8 * 1_024 * 1_024,
    maximumRequestBodyBytes: Int = 16 * 1_024 * 1_024,
    maximumSSELineBytes: Int = 64 * 1_024,
    maximumSSEEventBytes: Int = 8 * 1_024 * 1_024,
    maximumResponseBytes: Int = 32 * 1_024 * 1_024,
    maximumStreamEvents: Int = 50_000,
    maximumToolArgumentBytes: Int = 1 * 1_024 * 1_024,
    maximumOutputItems: Int = 256,
    maximumJSONDepth: Int = 64,
    maximumJSONNodes: Int = 100_000,
    maximumReplaySegments: Int = 64,
    maximumLocalStates: Int = 16,
    maximumLocalStateBytes: Int = 16 * 1_024 * 1_024,
    maximumLocalCacheBytes: Int = 64 * 1_024 * 1_024
  ) throws {
    let resolvedEndpoint: URL
    if let endpoint {
      resolvedEndpoint = endpoint
    } else if let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses") {
      resolvedEndpoint = defaultEndpoint
    } else {
      throw OpenAIResponsesProviderError.invalidConfiguration
    }
    let endpointComponents = URLComponents(
      url: resolvedEndpoint,
      resolvingAgainstBaseURL: false
    )

    guard
      resolvedEndpoint.scheme?.lowercased() == "https",
      resolvedEndpoint.host?.lowercased() == "api.openai.com",
      resolvedEndpoint.port == nil || resolvedEndpoint.port == 443,
      endpointComponents?.percentEncodedPath == "/v1/responses",
      resolvedEndpoint.user == nil,
      resolvedEndpoint.password == nil,
      resolvedEndpoint.query == nil,
      resolvedEndpoint.fragment == nil,
      !providerID.rawValue.isEmpty,
      providerID.rawValue.utf8.count <= 128,
      !displayName.isEmpty,
      displayName.utf8.count <= 256,
      !models.isEmpty,
      models.count <= 256,
      requestTimeout.isFinite,
      requestTimeout > 0,
      requestTimeout <= 600,
      (1...16_384).contains(maximumMessages),
      (1...2_048).contains(maximumTools),
      (1...4_096).contains(maximumIdentifierBytes),
      (1...32 * 1_024 * 1_024).contains(maximumInputValueBytes),
      (1...64 * 1_024 * 1_024).contains(maximumRequestBodyBytes),
      (1...1 * 1_024 * 1_024).contains(maximumSSELineBytes),
      (1...16 * 1_024 * 1_024).contains(maximumSSEEventBytes),
      (1...128 * 1_024 * 1_024).contains(maximumResponseBytes),
      (1...200_000).contains(maximumStreamEvents),
      (1...8 * 1_024 * 1_024).contains(maximumToolArgumentBytes),
      (1...4_096).contains(maximumOutputItems),
      (1...128).contains(maximumJSONDepth),
      (1...1_000_000).contains(maximumJSONNodes),
      (1...256).contains(maximumReplaySegments),
      (1...256).contains(maximumLocalStates),
      (1...64 * 1_024 * 1_024).contains(maximumLocalStateBytes),
      (1...256 * 1_024 * 1_024).contains(maximumLocalCacheBytes),
      maximumSSELineBytes <= maximumSSEEventBytes,
      maximumSSEEventBytes <= maximumResponseBytes,
      maximumToolArgumentBytes <= maximumSSEEventBytes,
      maximumLocalStateBytes <= maximumLocalCacheBytes
    else {
      throw OpenAIResponsesProviderError.invalidConfiguration
    }

    var modelIDs = Set<ModelID>()
    for model in models {
      guard
        model.providerID == providerID,
        !model.id.rawValue.isEmpty,
        model.id.rawValue.utf8.count <= maximumIdentifierBytes,
        !model.displayName.isEmpty,
        model.displayName.utf8.count <= 256,
        model.contextWindow.map({ $0 > 0 }) ?? true,
        model.maxOutputTokens.map({ $0 > 0 }) ?? true,
        modelIDs.insert(model.id).inserted
      else {
        throw OpenAIResponsesProviderError.invalidConfiguration
      }
    }

    self.endpoint = resolvedEndpoint
    self.providerID = providerID
    self.displayName = displayName
    self.models = models
    self.privacyMode = privacyMode
    self.requestTimeout = requestTimeout
    self.requestReasoningSummaries = requestReasoningSummaries
    self.maximumMessages = maximumMessages
    self.maximumTools = maximumTools
    self.maximumIdentifierBytes = maximumIdentifierBytes
    self.maximumInputValueBytes = maximumInputValueBytes
    self.maximumRequestBodyBytes = maximumRequestBodyBytes
    self.maximumSSELineBytes = maximumSSELineBytes
    self.maximumSSEEventBytes = maximumSSEEventBytes
    self.maximumResponseBytes = maximumResponseBytes
    self.maximumStreamEvents = maximumStreamEvents
    self.maximumToolArgumentBytes = maximumToolArgumentBytes
    self.maximumOutputItems = maximumOutputItems
    self.maximumJSONDepth = maximumJSONDepth
    self.maximumJSONNodes = maximumJSONNodes
    self.maximumReplaySegments = maximumReplaySegments
    self.maximumLocalStates = maximumLocalStates
    self.maximumLocalStateBytes = maximumLocalStateBytes
    self.maximumLocalCacheBytes = maximumLocalCacheBytes
  }
}
