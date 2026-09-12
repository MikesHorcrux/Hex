import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Mac application tools")
struct MacApplicationToolTests {
  @Test
  func listAndActivationRequireBoundAuthorization() async throws {
    let controller = ApplicationController()
    let listTool = MacListApplicationsTool(controller: controller)
    let activateTool = MacActivateApplicationTool(controller: controller)
    let context = ToolExecutionContext(runID: AgentRunID())
    let listCall = ToolCall(
      id: ToolCallID(rawValue: "mac-list"),
      name: "mac_list_applications",
      arguments: [:]
    )

    let deniedByBoundary = try await listTool.execute(listCall, in: context)
    #expect(deniedByBoundary.status == .failure)
    #expect(deniedByBoundary.output == .object(["error": .string("authorization_required")]))

    let listRequest = try await listTool.authorizationRequest(for: listCall, in: context)
    #expect(listRequest.capability.rawValue == "mac.application.read")
    let listResult = try await listTool.execute(listCall, in: context)
    #expect(listResult.status == .success)

    let activationCall = ToolCall(
      id: ToolCallID(rawValue: "mac-activate"),
      name: "mac_activate_application",
      arguments: ["bundle_id": .string("com.apple.Safari")]
    )
    let activationRequest = try await activateTool.authorizationRequest(
      for: activationCall,
      in: context
    )
    #expect(activationRequest.resource == "bundle:com.apple.Safari")
    let activationResult = try await activateTool.execute(activationCall, in: context)
    #expect(activationResult.status == .success)
    #expect(await controller.activatedBundleIdentifier == "com.apple.Safari")
  }

  private actor ApplicationController: MacApplicationControlling {
    private(set) var activatedBundleIdentifier: String?

    func runningApplications() async throws -> [MacApplicationSnapshot] {
      [
        MacApplicationSnapshot(
          bundleIdentifier: "com.apple.Safari",
          localizedName: "Safari",
          processIdentifier: 42,
          isActive: true,
          isHidden: false
        )
      ]
    }

    func activateApplication(
      bundleIdentifier: String
    ) async throws -> MacApplicationActivationResult {
      activatedBundleIdentifier = bundleIdentifier
      return MacApplicationActivationResult(bundleIdentifier: bundleIdentifier, wasRunning: true)
    }

    func openURL(_ url: URL) async throws {}
  }
}
