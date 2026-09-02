import Darwin
import Foundation
import HexCore
import Testing

@testable import HexPersistence

@Suite("Inference backend settings persistence")
struct JSONHexInferenceBackendSettingsStoreTests {
  @Test
  func savesAndLoadsPrivateSettingsWithoutAnAPIKeyField() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let fileURL = root.appendingPathComponent("inference-backends.json", isDirectory: false)
    let store = try JSONHexInferenceBackendSettingsStore(fileURL: fileURL)
    let settings = try HexInferenceBackendSettings(
      selectedBackend: .codexCompatibility,
      openAIModelID: "gpt-test",
      mlx: try HexMLXBackendSettings(),
      codex: try HexCodexCompatibilitySettings(
        executableURL: URL(fileURLWithPath: "/Users/test/bin/codex")
      )
    )

    try await store.save(settings)
    let loaded = try await store.load()
    let data = try Data(contentsOf: fileURL)
    let json = String(decoding: data, as: UTF8.self)

    #expect(loaded == settings)
    #expect(!json.contains("\"apiKey\""))
    #expect(!json.contains("\"secret\""))
    #expect(!json.contains("\"accessToken\""))
    #expect(!json.contains("\"refreshToken\""))

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  }

  @Test
  func rejectsSymlinkedSettingsFile() async throws {
    let root = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let realURL = root.appendingPathComponent("real.json", isDirectory: false)
    let realStore = try JSONHexInferenceBackendSettingsStore(fileURL: realURL)
    try await realStore.save(try HexInferenceBackendSettings())

    let linkURL = root.appendingPathComponent("link.json", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)
    let linkStore = try JSONHexInferenceBackendSettingsStore(fileURL: linkURL)

    do {
      _ = try await linkStore.load()
      Issue.record("Expected a symbolic-link settings path to be rejected.")
    } catch let error as JSONHexInferenceBackendSettingsStoreError {
      #expect(error == .unsafeFile)
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    let didResolve = resolvedPath.withUnsafeMutableBufferPointer { buffer in
      temporaryPath.withCString { source in
        Darwin.realpath(source, buffer.baseAddress) != nil
      }
    }
    guard didResolve else {
      throw JSONHexInferenceBackendSettingsStoreError.ioFailure
    }

    let resolvedPathBytes = resolvedPath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let directory = URL(
      fileURLWithPath: String(decoding: resolvedPathBytes, as: UTF8.self),
      isDirectory: true
    ).appendingPathComponent(
      "hex-inference-backends-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return directory
  }
}
