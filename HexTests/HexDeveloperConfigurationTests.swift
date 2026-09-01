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

  @Test
  func residentXPCIsTheDefaultRoute() {
    let configuration = HexDeveloperConfiguration(environment: [:])

    #expect(configuration.gatewayRoute.kind == .residentXPC)
    #expect(
      configuration.gatewayRoute.machServiceName
        == HexGatewayRoute.defaultMachServiceName
    )
  }

  @Test
  func inProcessRouteRequiresExplicitOptInAndCompleteSettings() {
    let workspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let configuration = HexDeveloperConfiguration(
      environment: [
        "HEX_OPENAI_API_KEY": "developer-test-key",
        "HEX_OPENAI_MODEL": "gpt-developer-test",
        "HEX_WORKSPACE_ROOT": workspaceRoot.path,
        "HEX_GATEWAY_MODE": "in-process",
        "HEX_ALLOW_IN_PROCESS_FALLBACK": "true",
      ]
    )

    #expect(configuration.gatewayRoute.kind == .developerInProcess)
  }

  @Test
  func incompleteFallbackFallsBackToResidentXPC() {
    let configuration = HexDeveloperConfiguration(
      environment: [
        "HEX_GATEWAY_MODE": "in-process",
        "HEX_ALLOW_IN_PROCESS_FALLBACK": "true",
      ]
    )

    #expect(configuration.gatewayRoute.kind == .residentXPC)
  }
}
