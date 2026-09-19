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
