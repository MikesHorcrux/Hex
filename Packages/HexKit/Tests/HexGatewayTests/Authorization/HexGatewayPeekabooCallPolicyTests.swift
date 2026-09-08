import HexCore
import Testing

@testable import HexGatewayKit

@Suite("Pinned Peekaboo operation classification")
struct HexGatewayPeekabooCallPolicyTests {
  @Test(arguments: ["app", "window", "dialog", "space", "dock", "menu"])
  func ordinaryListingDoesNotRequireAnActionObservation(_ tool: String) {
    #expect(
      HexGatewayPeekabooCallPolicy.classify(tool, arguments: ["action": .string("list")])
        == .read)
  }

  @Test(arguments: [
    "action", "type", "move", "press", "click", "scroll", "paste", "drag", "set_value",
  ])
  func directActionsAlwaysRequireAnObservation(_ tool: String) {
    #expect(HexGatewayPeekabooCallPolicy.classify(tool, arguments: [:]) == .mutation)
  }

  @Test(arguments: ["agent", "analyze", "browser", "unknown_future_tool"])
  func delegatedInferenceAndUnclassifiedToolsAreNotNativeActions(_ tool: String) {
    #expect(!HexGatewayPeekabooCallPolicy.isListed(tool))
    #expect(HexGatewayPeekabooCallPolicy.classify(tool, arguments: [:]) == .unsupported)
  }

  @Test
  func observationCannotSilentlyPressAWebElementOrFocusTheApp() {
    #expect(
      HexGatewayPeekabooCallPolicy.classify("see", arguments: ["web_focus": .boolean(true)])
        == .unsupported)
    #expect(
      HexGatewayPeekabooCallPolicy.classify("inspect_ui", arguments: ["web_focus": .boolean(true)])
        == .unsupported)
    #expect(
      HexGatewayPeekabooCallPolicy.classify(
        "image", arguments: ["capture_focus": .string("foreground")])
        == .mutation)
    #expect(
      HexGatewayPeekabooCallPolicy.classify(
        "menu", arguments: ["action": .string("list"), "foreground": .boolean(true)])
        == .mutation)
  }

  @Test
  func malformedAndNewActionVariantsNeverInheritReadAccess() {
    #expect(HexGatewayPeekabooCallPolicy.classify("app", arguments: [:]) == .unsupported)
    #expect(
      HexGatewayPeekabooCallPolicy.classify("app", arguments: ["action": .string("future_action")])
        == .unsupported)
    #expect(
      HexGatewayPeekabooCallPolicy.classify("clipboard", arguments: ["action": .string("clear")])
        == .mutation)
  }
}
