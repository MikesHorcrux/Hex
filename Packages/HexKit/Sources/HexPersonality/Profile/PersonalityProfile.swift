import Foundation

public struct PersonalityProfile: Codable, Equatable, Sendable {
  public let name: String
  public let identity: String
  public let voice: String
  public let traits: [String]
  public let values: [String]
  public let boundaries: [String]

  public init(
    name: String,
    identity: String,
    voice: String,
    traits: [String] = [],
    values: [String] = [],
    boundaries: [String] = []
  ) throws {
    guard Self.isValidRequired(name, maximumBytes: 256) else {
      throw PersonalityProfileError.invalidName
    }
    guard Self.isValidRequired(identity, maximumBytes: 16_384) else {
      throw PersonalityProfileError.invalidIdentity
    }
    guard Self.isValidRequired(voice, maximumBytes: 16_384) else {
      throw PersonalityProfileError.invalidVoice
    }
    for collection in [traits, values, boundaries] {
      try Self.validate(collection)
    }

    let allStrings = [name, identity, voice] + traits + values + boundaries
    let totalBytes = allStrings.reduce(into: 0) { total, value in
      total += value.utf8.count
    }
    guard totalBytes <= 128 * 1_024 else {
      throw PersonalityProfileError.profileTooLarge
    }

    self.name = name
    self.identity = identity
    self.voice = voice
    self.traits = traits
    self.values = values
    self.boundaries = boundaries
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      name: container.decode(String.self, forKey: .name),
      identity: container.decode(String.self, forKey: .identity),
      voice: container.decode(String.self, forKey: .voice),
      traits: container.decode([String].self, forKey: .traits),
      values: container.decode([String].self, forKey: .values),
      boundaries: container.decode([String].self, forKey: .boundaries)
    )
  }

  private static func validate(_ values: [String]) throws {
    guard values.count <= 64 else {
      throw PersonalityProfileError.invalidCollection
    }
    var normalized = Set<String>()
    for value in values {
      guard isValidRequired(value, maximumBytes: 4_096) else {
        throw PersonalityProfileError.invalidCollection
      }
      let key =
        value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")
        )
      guard normalized.insert(key).inserted else {
        throw PersonalityProfileError.duplicateCollectionValue
      }
    }
  }

  private static func isValidRequired(_ value: String, maximumBytes: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
  }
}
