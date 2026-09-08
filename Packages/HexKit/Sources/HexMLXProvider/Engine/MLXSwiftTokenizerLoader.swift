import Foundation
import MLXLMCommon
import Tokenizers

struct MLXSwiftTokenizerLoader: MLXLMCommon.TokenizerLoader, Sendable {
  func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
    let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
    return MLXSwiftTokenizer(upstream: tokenizer)
  }
}
