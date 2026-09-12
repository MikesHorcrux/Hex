import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

enum PersonalMemoryToolError: Error, Equatable, Sendable {
  case invalidArguments
  case scopeMismatch
  case authorizationRequired
  case authorizationStateUnavailable
  case invalidStore
  case invalidTimestamp
}
