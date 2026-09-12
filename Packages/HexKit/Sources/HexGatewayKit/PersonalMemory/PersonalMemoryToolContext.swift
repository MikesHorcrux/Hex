import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

struct PersonalMemoryToolContext: Sendable {
  let memoryStore: any PersonalMemoryStore
  let scope: PersonalMemoryScope
  let authorizationLedger: PersonalMemoryAuthorizationLedger
}
