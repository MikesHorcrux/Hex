import Foundation

public enum ConversationStorageFailure: String, Codable, Error, Sendable {
  case invalidRequest, revisionConflict, operationConflict, immutableEntry, unavailable
}
