import Foundation
import Testing

@testable import HexCore

@Suite("Resident runtime settings")
struct HexResidentRuntimeSettingsTests {
  @Test
  func roundTripsOnlyNonSecretSettingsWithCurrentSchema() throws {
    let settings = try HexResidentRuntimeSettings(
      modelID: "gpt-test",
      workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace")
    )
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(HexResidentRuntimeSettings.self, from: data)

    #expect(settings == decoded)
    #expect(settings.schemaVersion == HexResidentRuntimeSettings.currentSchemaVersion)
    #expect(!String(decoding: data, as: UTF8.self).contains("apiKey"))
  }

  @Test
  func rejectsNonFileWorkspaceAndUnsupportedSchema() throws {
    guard let nonFileURL = URL(string: "https://example.com/workspace") else {
      Issue.record("Could not prepare a non-file URL fixture.")
      return
    }
    do {
      _ = try HexResidentRuntimeSettings(
        modelID: "gpt-test",
        workspaceRoot: nonFileURL
      )
      Issue.record("Expected a relative workspace URL to be rejected.")
    } catch let error as HexResidentRuntimeSettingsError {
      #expect(error == .invalidWorkspaceRoot)
    }

    let unsupportedVersion = HexResidentRuntimeSettings.currentSchemaVersion + 1
    do {
      _ = try HexResidentRuntimeSettings(
        modelID: "gpt-test",
        workspaceRoot: URL(fileURLWithPath: "/tmp/hex-workspace"),
        schemaVersion: unsupportedVersion
      )
      Issue.record("Expected an unsupported schema version to be rejected.")
    } catch let error as HexResidentRuntimeSettingsError {
      #expect(error == .unsupportedSchemaVersion(unsupportedVersion))
    }
  }
}
