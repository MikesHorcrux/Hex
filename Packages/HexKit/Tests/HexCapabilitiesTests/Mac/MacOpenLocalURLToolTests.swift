import Foundation
import HexCapabilities
import HexCore
import Testing

@Suite("Local browser previews")
struct MacOpenLocalURLToolTests {
  @Test(arguments: ["http://127.0.0.1:4173/", "http://[::1]:8765/page", "https://127.0.0.1:8443/"])
  func opensOnlyTheAuthorizedURLAndApplication(url: String) async throws {
    let controller = Controller()
    let tool = MacOpenLocalURLTool(controller: controller)
    let context = ToolExecutionContext(runID: AgentRunID())
    let call = ToolCall(
      name: "mac_open_local_url",
      arguments: [
        "url": .string(url), "bundle_id": .string("com.apple.Safari"),
      ])
    #expect(try await tool.execute(call, in: context).status == .failure)
    #expect(await controller.opened.isEmpty)
    let request = try await tool.authorizationRequest(for: call, in: context)
    #expect(request.capability.rawValue == "mac.application.control")
    #expect(request.resource?.contains(url) == true)
    #expect(request.resource?.contains("com.apple.Safari") == true)
    let result = try await tool.execute(call, in: context)
    #expect(result.status == .success)
    #expect(await controller.opened == [url + "|com.apple.Safari"])
    #expect(try await tool.execute(call, in: context).status == .failure)
    #expect(await controller.opened.count == 1)
  }

  @Test(arguments: [
    "https://example.com/", "http://192.168.1.1/", "file:///tmp/site.html",
    "javascript:alert(1)", "http://127.0.0.1.example.com/", "http://user@127.0.0.1:4173/",
    "http://127.0.0.1:0/", "http://localhost:4173/", "http://2130706433:4173/",
  ])
  func rejectsNonliteralLoopbackAndCredentialBearingTargets(url: String) async throws {
    let controller = Controller()
    let tool = MacOpenLocalURLTool(controller: controller)
    let call = ToolCall(
      name: "mac_open_local_url",
      arguments: [
        "url": .string(url), "bundle_id": .string("com.apple.Safari"),
      ])
    let context = ToolExecutionContext(runID: AgentRunID())
    await #expect(throws: (any Error).self) {
      _ = try await tool.authorizationRequest(for: call, in: context)
    }
    #expect(try await tool.execute(call, in: context).status == .failure)
    #expect(await controller.opened.isEmpty)
  }

  @Test
  func changingTargetAfterAuthorizationDoesNotDispatch() async throws {
    let controller = Controller()
    let tool = MacOpenLocalURLTool(controller: controller)
    let context = ToolExecutionContext(runID: AgentRunID())
    let call = ToolCall(
      name: "mac_open_local_url",
      arguments: [
        "url": .string("http://127.0.0.1:4173/"), "bundle_id": .string("com.apple.Safari"),
      ])
    _ = try await tool.authorizationRequest(for: call, in: context)
    let changed = ToolCall(
      id: call.id, name: call.name,
      arguments: [
        "url": .string("http://127.0.0.1:9999/"), "bundle_id": .string("com.apple.Safari"),
      ])
    #expect(try await tool.execute(changed, in: context).status == .failure)
    #expect(await controller.opened.isEmpty)
  }

  private actor Controller: MacLocalURLControlling {
    var opened: [String] = []
    func openLocalURL(_ url: URL, bundleIdentifier: String) async throws {
      opened.append(url.absoluteString + "|" + bundleIdentifier)
    }
  }
}
