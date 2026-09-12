import Dispatch
import Foundation
import HexCapabilities
import HexCore
import HexPersonality

enum PersonalMemoryToolName: String, Sendable {
  case list = "personal_memory_list"
  case search = "personal_memory_search"
  case upsert = "personal_memory_upsert"
  case delete = "personal_memory_delete"
}
