import Testing

@testable import Hex

@Suite("Start at login")
struct HexStartAtLoginTests {
  @Test @MainActor
  func missingBundledHelperIsPresentedAsPending() async {
    let model = HexStartAtLoginModel(controller: FakeController(status: .notFound))
    await model.refresh()

    #expect(model.status == .notFound)
    #expect(!model.canChange)

    model.toggle()

    #expect(model.message == "Start at login is pending the bundled gateway helper.")
  }

  private actor FakeController: HexGatewayLifecycleControlling {
    let currentStatus: HexGatewayLifecycleStatus

    init(status: HexGatewayLifecycleStatus) {
      currentStatus = status
    }

    func status() async -> HexGatewayLifecycleStatus {
      currentStatus
    }

    func register() async throws {}

    func unregister() async throws {}
  }
}
