import Foundation

struct JSONPersonalityProfileStorePersistedProfile: Codable, Sendable {
  let schemaVersion: Int
  let profile: PersonalityProfile
}
