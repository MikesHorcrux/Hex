import Foundation

struct OpenAIFunctionCallAssembly: Sendable {
  let itemID: String
  let outputIndex: Int
  let callID: String
  let name: String
  var argumentBytes: Data
  var finalArguments: String?
  var emitted: Bool
}
