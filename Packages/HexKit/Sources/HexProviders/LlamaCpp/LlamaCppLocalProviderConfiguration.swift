import Foundation
import HexCore

public struct LlamaCppLocalModelConfiguration: Equatable, Sendable {
  public let modelID: ModelID
  public let displayName: String
  public let contextWindow: Int?
  public let maximumOutputTokens: Int
  public let supportsToolCalling: Bool
  public let supportsParallelToolCalling: Bool

  public init(
    modelID: ModelID,
    displayName: String,
    contextWindow: Int?,
    maximumOutputTokens: Int,
    supportsToolCalling: Bool,
    supportsParallelToolCalling: Bool
  ) throws {
    guard
      !modelID.rawValue.isEmpty,
      modelID.rawValue.utf8.count <= 256,
      !modelID.rawValue.contains("\0"),
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      displayName.utf8.count <= 512,
      !displayName.contains("\0"),
      (1...1_000_000).contains(maximumOutputTokens),
      contextWindow.map({ (1...1_000_000).contains($0) && maximumOutputTokens <= $0 }) ?? true,
      !supportsParallelToolCalling || supportsToolCalling
    else {
      throw LlamaCppLocalInferenceProviderError.invalidModelConfiguration
    }
    self.modelID = modelID
    self.displayName = displayName
    self.contextWindow = contextWindow
    self.maximumOutputTokens = maximumOutputTokens
    self.supportsToolCalling = supportsToolCalling
    self.supportsParallelToolCalling = supportsParallelToolCalling
  }
}

public struct LlamaCppLocalProviderConfiguration: Equatable, Sendable {
  public let providerID: ProviderID
  public let displayName: String
  public let endpoint: URL
  public let models: [LlamaCppLocalModelConfiguration]
  public let maximumBufferedEvents: Int
  public let requestTimeout: TimeInterval

  public init(
    providerID: ProviderID,
    displayName: String,
    endpoint: URL,
    models: [LlamaCppLocalModelConfiguration],
    maximumBufferedEvents: Int = 128,
    requestTimeout: TimeInterval = 60 * 60
  ) throws {
    guard
      !providerID.rawValue.isEmpty,
      providerID.rawValue.utf8.count <= 256,
      !providerID.rawValue.contains("\0"),
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      displayName.utf8.count <= 512,
      !displayName.contains("\0"),
      let scheme = endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https",
      endpoint.host != nil,
      endpoint.user == nil,
      endpoint.password == nil,
      endpoint.fragment == nil,
      !models.isEmpty,
      Set(models.map(\.modelID)).count == models.count,
      (1...4_096).contains(maximumBufferedEvents),
      requestTimeout.isFinite,
      requestTimeout > 0
    else {
      throw LlamaCppLocalInferenceProviderError.invalidProviderConfiguration
    }
    self.providerID = providerID
    self.displayName = displayName
    self.endpoint = endpoint
    self.models = models
    self.maximumBufferedEvents = maximumBufferedEvents
    self.requestTimeout = requestTimeout
  }
}
