import Darwin
import Foundation
import HexPersonality
import Testing

@Suite("JSON personality profile store")
struct JSONPersonalityProfileStoreTests {
  @Test
  func roundTripsAcrossStoreInstancesAndUsesPrivateAtomicFiles() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("profile.json", isDirectory: false)
    let profile = try makeProfile()

    try await JSONPersonalityProfileStore(fileURL: fileURL).save(profile)
    let loaded = try await JSONPersonalityProfileStore(fileURL: fileURL).load()

    #expect(loaded == profile)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ).filter { $0.lastPathComponent.contains(".tmp") }.isEmpty
    )
  }

  @Test
  func missingProfileIsEmptyAndMalformedOrUnsupportedDataFailsClosed() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("profile.json", isDirectory: false)
    let store = try JSONPersonalityProfileStore(fileURL: fileURL)

    #expect(try await store.load() == nil)

    try Data("not-json".utf8).write(to: fileURL)
    try setPrivatePermissions(at: fileURL)
    await #expect(throws: PersonalityProfileStoreError.malformedProfile) {
      _ = try await store.load()
    }

    let unsupported = Data(#"{"profile":{},"schemaVersion":99}"#.utf8)
    try unsupported.write(to: fileURL, options: [.atomic])
    try setPrivatePermissions(at: fileURL)
    await #expect(throws: PersonalityProfileStoreError.malformedProfile) {
      _ = try await store.load()
    }
  }

  @Test
  func rejectsOversizedAndSymlinkedProfileFiles() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let oversizedURL = directory.appendingPathComponent("oversized.json", isDirectory: false)
    let oversizedStore = try JSONPersonalityProfileStore(
      fileURL: oversizedURL,
      maximumBytes: 128
    )
    try Data(repeating: 0x20, count: 129).write(to: oversizedURL, options: [.atomic])
    try setPrivatePermissions(at: oversizedURL)
    await #expect(throws: PersonalityProfileStoreError.profileTooLarge) {
      _ = try await oversizedStore.load()
    }

    let realURL = directory.appendingPathComponent("real.json", isDirectory: false)
    try await JSONPersonalityProfileStore(fileURL: realURL).save(try makeProfile())
    let linkURL = directory.appendingPathComponent("link.json", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)
    let linkStore = try JSONPersonalityProfileStore(fileURL: linkURL)
    await #expect(throws: PersonalityProfileStoreError.unsafeFile) {
      _ = try await linkStore.load()
    }
  }

  @Test
  func saveHonorsItsEncodedSizeBoundWithoutCreatingAPartialFile() async throws {
    let directory = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let fileURL = directory.appendingPathComponent("profile.json", isDirectory: false)
    let store = try JSONPersonalityProfileStore(fileURL: fileURL, maximumBytes: 1)

    await #expect(throws: PersonalityProfileStoreError.profileTooLarge) {
      try await store.save(try makeProfile())
    }
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(
      try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      ).filter { $0.lastPathComponent.contains(".tmp") }.isEmpty
    )
  }

  private func makeProfile() throws -> PersonalityProfile {
    try PersonalityProfile(
      name: "Hex",
      identity: "A personal Mac companion.",
      voice: "Direct, warm, and precise.",
      traits: ["curious"],
      values: ["user agency"],
      boundaries: ["Never claim an unverified action."]
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = try resolvedTemporaryDirectory()
      .appendingPathComponent(
        "hex-profile-store-" + UUID().uuidString,
        isDirectory: true
      )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func resolvedTemporaryDirectory() throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = FileManager.default.temporaryDirectory.path.withCString { source in
      realpath(source, &buffer) != nil
    }
    guard resolved else {
      throw PersonalityProfileStoreError.ioFailure
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return URL(
      fileURLWithPath: String(decoding: bytes, as: UTF8.self),
      isDirectory: true
    )
  }

  private func setPrivatePermissions(at url: URL) throws {
    guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
      throw PersonalityProfileStoreError.ioFailure
    }
  }
}
