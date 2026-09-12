import Foundation

public enum AgentContextCompactionValidationError: Error, Equatable, Sendable {
  case invalidIdentity, invalidSources, invalidSummary, invalidProviderOrModel, invalidEstimates
  case invalidUsage
}
