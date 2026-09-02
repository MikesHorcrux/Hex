import Foundation

/// An owner-only, atomically replaced JSON store for the current personality profile.
public actor JSONPersonalityProfileStore: PersonalityProfileStore {
  public let fileURL: URL

  private let maximumBytes: Int

  public init(
    fileURL: URL,
    maximumBytes: Int = 256 * 1_024
  ) throws {
    let standardizedURL = fileURL.standardizedFileURL
    guard JSONPersonalityStoreFileSupport.isValidFileURL(standardizedURL) else {
      throw PersonalityProfileStoreError.invalidFileURL
    }
    guard (1...4 * 1_024 * 1_024).contains(maximumBytes) else {
      throw PersonalityProfileStoreError.invalidMaximumBytes
    }
    self.fileURL = standardizedURL
    self.maximumBytes = maximumBytes
  }

  public func load() async throws -> PersonalityProfile? {
    try Task.checkCancellation()
    let fileURL = self.fileURL
    let maximumBytes = self.maximumBytes
    return try withStoreErrorMapping {
      try JSONPersonalityStoreFileSupport.withFileLock(fileURL: fileURL) {
        guard
          let data = try JSONPersonalityStoreFileSupport.readBoundedData(
            from: fileURL,
            maximumBytes: maximumBytes
          )
        else {
          return nil
        }
        do {
          let snapshot = try JSONDecoder().decode(PersistedProfile.self, from: data)
          guard snapshot.schemaVersion == Self.schemaVersion else {
            throw PersonalityProfileStoreError.malformedProfile
          }
          return snapshot.profile
        } catch let error as PersonalityProfileStoreError {
          throw error
        } catch is DecodingError {
          throw PersonalityProfileStoreError.malformedProfile
        } catch {
          throw PersonalityProfileStoreError.ioFailure
        }
      }
    }
  }

  public func save(_ profile: PersonalityProfile) async throws {
    try Task.checkCancellation()
    let snapshot = PersistedProfile(schemaVersion: Self.schemaVersion, profile: profile)
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(snapshot)
    } catch {
      throw PersonalityProfileStoreError.encodingFailure
    }
    guard data.count <= maximumBytes else {
      throw PersonalityProfileStoreError.profileTooLarge
    }
    try Task.checkCancellation()

    let fileURL = self.fileURL
    let maximumBytes = self.maximumBytes
    try withStoreErrorMapping {
      try JSONPersonalityStoreFileSupport.withFileLock(fileURL: fileURL) {
        try JSONPersonalityStoreFileSupport.writeDurably(
          data,
          to: fileURL,
          maximumBytes: maximumBytes
        )
      }
    }
  }

  private func withStoreErrorMapping<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    do {
      return try operation()
    } catch let error as PersonalityProfileStoreError {
      throw error
    } catch let error as JSONPersonalityStoreFileSupport.Failure {
      switch error {
      case .invalidFileURL:
        throw PersonalityProfileStoreError.invalidFileURL
      case .unsafeFile:
        throw PersonalityProfileStoreError.unsafeFile
      case .lockFailure:
        throw PersonalityProfileStoreError.lockFailure
      case .ioFailure:
        throw PersonalityProfileStoreError.ioFailure
      case .tooLarge:
        throw PersonalityProfileStoreError.profileTooLarge
      }
    }
  }

  private struct PersistedProfile: Codable, Sendable {
    let schemaVersion: Int
    let profile: PersonalityProfile
  }

  private static let schemaVersion = 1
}
