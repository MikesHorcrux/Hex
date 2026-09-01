import Darwin
import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Resident persistence")
struct HexResidentPersistenceTests {
  @Test
  func returnsNoSettingsBeforeFirstSave() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let fileURL = root.appendingPathComponent("resident.json", isDirectory: false)
    let store = try JSONHexResidentRuntimeSettingsStore(fileURL: fileURL)

    let loaded = try await store.load()

    #expect(loaded == nil)
  }

  @Test
  func savesAndLoadsPrivateBoundedSettings() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let fileURL =
      root
      .appendingPathComponent("state", isDirectory: true)
      .appendingPathComponent("resident.json", isDirectory: false)
    let store = try JSONHexResidentRuntimeSettingsStore(fileURL: fileURL)
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-test",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )

    try await store.save(settings)
    let loaded = try await store.load()

    #expect(loaded == settings)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test
  func rejectsSymlinkAndOversizedSettingsFiles() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let realURL = root.appendingPathComponent("real.json", isDirectory: false)
    let realStore = try JSONHexResidentRuntimeSettingsStore(fileURL: realURL)
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-test",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )
    try await realStore.save(settings)

    let linkURL = root.appendingPathComponent("link.json", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)
    let linkStore = try JSONHexResidentRuntimeSettingsStore(fileURL: linkURL)
    do {
      _ = try await linkStore.load()
      Issue.record("Expected a symbolic-link settings path to be rejected.")
    } catch let error as JSONHexResidentRuntimeSettingsStoreError {
      #expect(error == .unsafeFile)
    }

    let oversizedURL = root.appendingPathComponent("oversized.json", isDirectory: false)
    let oversizedStore = try JSONHexResidentRuntimeSettingsStore(
      fileURL: oversizedURL,
      maximumBytes: 128
    )
    try Data(repeating: 0x20, count: 129).write(to: oversizedURL, options: [.atomic])
    try setPrivatePermissions(at: oversizedURL)
    do {
      _ = try await oversizedStore.load()
      Issue.record("Expected an oversized settings file to be rejected.")
    } catch let error as JSONHexResidentRuntimeSettingsStoreError {
      #expect(error == .settingsTooLarge)
    }
  }

  @Test
  func rejectsSymlinkAncestors() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let target = root.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let redirect = root.appendingPathComponent("redirect", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: target)

    let fileURL =
      redirect
      .appendingPathComponent("nested", isDirectory: true)
      .appendingPathComponent("resident.json", isDirectory: false)
    let store = try JSONHexResidentRuntimeSettingsStore(fileURL: fileURL)

    do {
      _ = try await store.load()
      Issue.record("Expected a symbolic-link ancestor to be rejected.")
    } catch let error as JSONHexResidentRuntimeSettingsStoreError {
      #expect(error == .unsafeFile)
    }
  }

  @Test
  func rejectsUnsupportedPersistedSchemaAndUsesExplicitKeychainIdentity() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let fileURL = root.appendingPathComponent("resident.json", isDirectory: false)
    let store = try JSONHexResidentRuntimeSettingsStore(fileURL: fileURL)
    let data = Data(
      #"{"schemaVersion":99,"modelID":"gpt-test","workspaceRoot":"/tmp/hex-workspace"}"#.utf8
    )
    try data.write(to: fileURL, options: [.atomic])
    try setPrivatePermissions(at: fileURL)

    do {
      _ = try await store.load()
      Issue.record("Expected an unsupported settings schema to be rejected.")
    } catch let error as JSONHexResidentRuntimeSettingsStoreError {
      #expect(error == .malformedSettings)
    }

    #expect(
      KeychainHexSecretStore.defaultAccessGroup
        == "5V5PZUN2HG.com.lunarmothstudios.Hex.resident"
    )
    #expect(KeychainHexSecretStore.defaultService == "com.lunarmothstudios.Hex.resident")
    #expect(KeychainHexSecretStore.defaultAccount == "openai-api-key")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hex-resident-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }

  private func setPrivatePermissions(at url: URL) throws {
    let result = url.path.withCString { path in
      Darwin.chmod(path, S_IRUSR | S_IWUSR)
    }
    guard result == 0 else {
      throw JSONHexResidentRuntimeSettingsStoreError.ioFailure
    }
  }
}
