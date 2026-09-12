import Foundation

public enum ProcessSessionError: String, Error, Codable, Sendable, LocalizedError {
  case unavailable, invalidRequest, revisionConflict, capacity, unauthorized, inputUncertain
  case outputUnavailable, cleanupUnconfirmed, operationConflict
  public var errorDescription: String? { "Process session: " + rawValue }
}
