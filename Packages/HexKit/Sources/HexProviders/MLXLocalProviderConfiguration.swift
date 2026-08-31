import Foundation
import HexCore

public struct MLXLocalProviderConfiguration: Equatable, Sendable {
  public let providerID: ProviderID
  public let displayName: String
  public let models: [MLXLocalModelConfiguration]
  public let maximumBufferedEvents: Int

  public init(
    providerID: ProviderID,
    displayName: String,
    models: [MLXLocalModelConfiguration],
    maximumBufferedEvents: Int = 64
  ) throws {
    let modelIDs = models.map(\.modelID)
    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !providerID.rawValue.isEmpty,
      providerID.rawValue.utf8.count <= 256,
      !providerID.rawValue.contains("\0"),
      !trimmedName.isEmpty,
      displayName.utf8.count <= 512,
      !displayName.contains("\0"),
      (1...32).contains(models.count),
      Set(modelIDs).count == modelIDs.count,
      (1...1_024).contains(maximumBufferedEvents)
    else {
      throw MLXLocalInferenceProviderError.invalidProviderConfiguration
    }
    self.providerID = providerID
    self.displayName = displayName
    self.models = models
    self.maximumBufferedEvents = maximumBufferedEvents
  }
}
