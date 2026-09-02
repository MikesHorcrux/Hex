import Foundation

enum HexPersonalityInputLimits {
  static let profileNameBytes = 256
  static let profileTextBytes = 16_384
  static let collectionEntryBytes = 4_096
  static let collectionEntryCount = 64
  static let profileTotalBytes = 128 * 1_024
  static let memoryTextBytes = 16_384
  static let queryTextBytes = 4_096
  static let memoryListLimit = 256

  static func bounded(_ value: String, maximumBytes: Int) -> String {
    guard maximumBytes > 0, value.utf8.count > maximumBytes else {
      return value
    }

    var bytes = Array(value.utf8.prefix(maximumBytes))
    while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
      bytes.removeLast()
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  static func boundedCollectionText(_ value: String) -> String {
    let maximumBytes = collectionEntryCount * collectionEntryBytes + collectionEntryCount
    return bounded(value, maximumBytes: maximumBytes)
  }

  static func collectionValues(from value: String) -> [String] {
    value
      .split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
