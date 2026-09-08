import Foundation
import HexCore

public struct OpenAIResponsesConfiguration: Equatable, Sendable {
  /// The endpoint is derived from `service`. Custom hosts and paths are rejected so neither API
  /// keys nor ChatGPT OAuth tokens can be redirected to an unrelated origin.
  public let endpoint: URL
  public let service: OpenAIResponsesService
  public let providerID: ProviderID
  public let displayName: String
  public let models: [ModelDescriptor]
  public let privacyMode: OpenAIResponsesPrivacyMode
  public let requestTimeout: TimeInterval
  public let reasoningEffort: OpenAIResponsesReasoningEffort
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
  public let maximumIssuedResponseIDs: Int
  public let maximumIssuedResponseIDBytes: Int
  public let maximumServerStates: Int
  public let maximumServerStateBytes: Int
  public let maximumServerCacheBytes: Int
  public let maximumLocalStates: Int
  public let maximumLocalStateBytes: Int
  public let maximumLocalCacheBytes: Int
  public let userAgent: String
  public let originator: String

  public init(
    service: OpenAIResponsesService = .platformAPI,
    endpoint: URL? = nil,
    providerID: ProviderID = ProviderID(rawValue: "openai"),
    displayName: String? = nil,
    models: [ModelDescriptor],
    privacyMode: OpenAIResponsesPrivacyMode? = nil,
    requestTimeout: TimeInterval = 120,
    reasoningEffort: OpenAIResponsesReasoningEffort = .low,
    requestReasoningSummaries: Bool = true,
    maximumMessages: Int = 4_096,
    maximumTools: Int = 512,
    maximumIdentifierBytes: Int = 512,
    maximumInputValueBytes: Int = 8 * 1_024 * 1_024,
    maximumRequestBodyBytes: Int = 16 * 1_024 * 1_024,
    maximumSSELineBytes: Int = 8 * 1_024 * 1_024,
    maximumSSEEventBytes: Int = 8 * 1_024 * 1_024,
    maximumResponseBytes: Int = 32 * 1_024 * 1_024,
    maximumStreamEvents: Int = 50_000,
    maximumToolArgumentBytes: Int = 1 * 1_024 * 1_024,
    maximumOutputItems: Int = 256,
    maximumJSONDepth: Int = 64,
    maximumJSONNodes: Int = 100_000,
    maximumReplaySegments: Int = 64,
    maximumIssuedResponseIDs: Int = 16_384,
    maximumIssuedResponseIDBytes: Int = 4 * 1_024 * 1_024,
    maximumServerStates: Int = 64,
    maximumServerStateBytes: Int = 16 * 1_024 * 1_024,
    maximumServerCacheBytes: Int = 64 * 1_024 * 1_024,
    maximumLocalStates: Int = 16,
    maximumLocalStateBytes: Int = 16 * 1_024 * 1_024,
    maximumLocalCacheBytes: Int = 64 * 1_024 * 1_024,
    userAgent: String = "Hex/1.0",
    originator: String = "hex"
  ) throws {
    guard let serviceEndpoint = service.endpoint else {
      throw OpenAIResponsesProviderError.invalidConfiguration
    }
    let resolvedEndpoint = endpoint ?? serviceEndpoint
    let resolvedDisplayName = displayName ?? service.displayName
    let resolvedPrivacyMode = privacyMode ?? service.defaultPrivacyMode
    let endpointComponents = URLComponents(
      url: resolvedEndpoint,
      resolvingAgainstBaseURL: false
    )
    let serviceEndpointComponents = URLComponents(
      url: serviceEndpoint,
      resolvingAgainstBaseURL: false
    )

    guard
      endpointComponents?.scheme?.lowercased() == "https",
      endpointComponents?.host?.lowercased() == serviceEndpointComponents?.host?.lowercased(),
      resolvedEndpoint.port == nil || resolvedEndpoint.port == 443,
      endpointComponents?.percentEncodedPath == serviceEndpointComponents?.percentEncodedPath,
      resolvedEndpoint.user == nil,
      resolvedEndpoint.password == nil,
      resolvedEndpoint.query == nil,
      resolvedEndpoint.fragment == nil,
      !providerID.rawValue.isEmpty,
      providerID.rawValue.utf8.count <= 128,
      !resolvedDisplayName.isEmpty,
      resolvedDisplayName.utf8.count <= 256,
      Self.isPrintableASCII(userAgent, maximumBytes: 256),
      Self.isPrintableASCII(originator, maximumBytes: 128),
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
      (1...16 * 1_024 * 1_024).contains(maximumSSELineBytes),
      (1...16 * 1_024 * 1_024).contains(maximumSSEEventBytes),
      (1...128 * 1_024 * 1_024).contains(maximumResponseBytes),
      (1...200_000).contains(maximumStreamEvents),
      (1...8 * 1_024 * 1_024).contains(maximumToolArgumentBytes),
      (1...4_096).contains(maximumOutputItems),
      (1...128).contains(maximumJSONDepth),
      (1...1_000_000).contains(maximumJSONNodes),
      (1...256).contains(maximumReplaySegments),
      (1...1_000_000).contains(maximumIssuedResponseIDs),
      (1...64 * 1_024 * 1_024).contains(maximumIssuedResponseIDBytes),
      (1...1_024).contains(maximumServerStates),
      (1...64 * 1_024 * 1_024).contains(maximumServerStateBytes),
      (1...256 * 1_024 * 1_024).contains(maximumServerCacheBytes),
      (1...256).contains(maximumLocalStates),
      (1...64 * 1_024 * 1_024).contains(maximumLocalStateBytes),
      (1...256 * 1_024 * 1_024).contains(maximumLocalCacheBytes),
      maximumSSELineBytes <= maximumSSEEventBytes,
      maximumSSEEventBytes <= maximumResponseBytes,
      maximumToolArgumentBytes <= maximumSSEEventBytes,
      maximumServerStateBytes <= maximumServerCacheBytes,
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
    self.service = service
    self.providerID = providerID
    self.displayName = resolvedDisplayName
    self.models = models
    self.privacyMode = resolvedPrivacyMode
    self.requestTimeout = requestTimeout
    self.reasoningEffort = reasoningEffort
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
    self.maximumIssuedResponseIDs = maximumIssuedResponseIDs
    self.maximumIssuedResponseIDBytes = maximumIssuedResponseIDBytes
    self.maximumServerStates = maximumServerStates
    self.maximumServerStateBytes = maximumServerStateBytes
    self.maximumServerCacheBytes = maximumServerCacheBytes
    self.maximumLocalStates = maximumLocalStates
    self.maximumLocalStateBytes = maximumLocalStateBytes
    self.maximumLocalCacheBytes = maximumLocalCacheBytes
    self.userAgent = userAgent
    self.originator = originator
  }

  private static func isPrintableASCII(_ value: String, maximumBytes: Int) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
    return bytes.allSatisfy { (0x21...0x7E).contains($0) }
  }
}
