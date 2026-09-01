import Foundation
import Testing

@testable import Hex

@Suite("Developer configuration")
struct HexDeveloperConfigurationTests {
  @Test
  func missingLiveSettingsExplainTheSetupWithoutExposingSecrets() {
    let configuration = HexDeveloperConfiguration(environment: [:])

    do {
      _ = try configuration.liveValues()
      Issue.record("Expected live configuration to require explicit settings.")
    } catch let error as HexDeveloperConfiguration.ConfigurationError {
      #expect(
        error.localizedDescription
          == "Live developer mode is not configured. Set HEX_OPENAI_API_KEY, HEX_OPENAI_MODEL, HEX_WORKSPACE_ROOT before running Hex."
      )
    } catch {
      Issue.record("Unexpected configuration error: \(error)")
    }
  }

  @Test
  func explicitSettingsPreserveConfiguredModelAndWorkspace() throws {
    let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let configuration = HexDeveloperConfiguration(
      environment: [
        "HEX_OPENAI_API_KEY": "developer-test-key",
        "HEX_OPENAI_MODEL": "gpt-developer-test",
        "HEX_WORKSPACE_ROOT": workspaceRoot.path,
      ]
    )

    let values = try configuration.liveValues()
    #expect(values.apiKey == "developer-test-key")
    #expect(values.modelID == "gpt-developer-test")
    #expect(values.workspaceRoot == workspaceRoot.resolvingSymlinksInPath())
  }
}
