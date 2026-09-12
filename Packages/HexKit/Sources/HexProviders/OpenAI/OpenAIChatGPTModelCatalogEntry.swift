import Foundation
import HexCore
import OSLog

struct OpenAIChatGPTModelCatalogEntry: Decodable {
  let slug: String
  let displayName: String
  let visibility: String
  let priority: Int?
  let contextWindow: Int?
  let supportedReasoningLevels: [OpenAIChatGPTModelCatalogEntryEffort]?
  let defaultReasoningLevel: String?
  let supportsReasoningSummaryParameter: Bool?
  let inputModalities: [String]?

  enum CodingKeys: String, CodingKey {
    case slug
    case displayName = "display_name"
    case visibility
    case priority
    case contextWindow = "context_window"
    case supportedReasoningLevels = "supported_reasoning_levels"
    case defaultReasoningLevel = "default_reasoning_level"
    case supportsReasoningSummaryParameter = "supports_reasoning_summary_parameter"
    case inputModalities = "input_modalities"
  }
}
