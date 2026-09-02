/// Durable storage for the current personality profile.
///
/// A missing profile is represented by `nil`; implementations must not return a partially decoded
/// or otherwise unvalidated profile.
public protocol PersonalityProfileStore: Sendable {
  func load() async throws -> PersonalityProfile?

  func save(_ profile: PersonalityProfile) async throws
}
