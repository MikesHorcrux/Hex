import XCTest

final class HexUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  func testFirstAgentSurfaceLaunches() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--hex-skip-onboarding"]
    app.launch()

    XCTAssertTrue(app.textViews["promptComposer"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["sendPromptButton"].exists)
  }
}
