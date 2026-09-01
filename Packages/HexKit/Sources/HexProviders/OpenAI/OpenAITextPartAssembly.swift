import Foundation

struct OpenAITextPartAssembly: Sendable {
  let outputIndex: Int
  let partType: String
  var textBytes: Data
  var finalText: String?
  var partCompleted: Bool
}
