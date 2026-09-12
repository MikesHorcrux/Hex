import Foundation
import HexCore

public enum HexSelfKnowledgeServiceError: Error, Equatable, Sendable {
  case duplicateRun
  case capacityExceeded
  case runUnavailable
}
