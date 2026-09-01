import CryptoKit
import Foundation
import HexCore

struct OpenAIMessageFingerprint: Equatable, Sendable {
  let digest: Data

  static func make(for message: Message) throws -> OpenAIMessageFingerprint {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(message)

    return OpenAIMessageFingerprint(digest: Data(SHA256.hash(data: data)))
  }
}
