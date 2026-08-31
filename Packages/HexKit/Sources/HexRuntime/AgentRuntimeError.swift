import Foundation
import HexCore

public enum AgentRuntimeError: Error, LocalizedError, Codable, Equatable, Sendable {
  case duplicateRun(AgentRunID)
  case invalidConfiguration(String)
  case invalidRequest(String)
  case modelUnavailable(ModelID)
  case unsupportedCapability(InferenceCapability)
  case providerFailure(String)
  case protocolViolation(String)
  case budgetExceeded(String)
  case authorizationFailure(String)
  case toolExecutionFailure(String)
  case journalFailure(String)
  case invalidState(String)

  public var errorDescription: String? {
    switch self {
    case .duplicateRun(let runID):
      "Run \(runID) is already active or durably recorded."
    case .invalidConfiguration(let message),
      .invalidRequest(let message),
      .providerFailure(let message),
      .protocolViolation(let message),
      .budgetExceeded(let message),
      .authorizationFailure(let message),
      .toolExecutionFailure(let message),
      .journalFailure(let message),
      .invalidState(let message):
      message
    case .modelUnavailable(let modelID):
      "Model \(modelID) is unavailable from the selected provider."
    case .unsupportedCapability(let capability):
      "The selected provider and model do not support \(capability.rawValue)."
    }
  }
}
