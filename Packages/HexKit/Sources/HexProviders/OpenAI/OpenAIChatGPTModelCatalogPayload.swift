import Foundation
import HexCore
import OSLog

struct OpenAIChatGPTModelCatalogPayload: Decodable {
  let models: [OpenAIChatGPTModelCatalogEntry]
}
