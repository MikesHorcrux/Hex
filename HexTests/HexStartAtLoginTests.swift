import Testing

@testable import Hex

@Suite("Start at login")
struct HexStartAtLoginTests {
  @Test @MainActor
  func blockedReadinessDoesNotInvokeLifecycleController() async {
    let controller = SpyController(status: .notRegistered)
    let model = HexStartAtLoginModel(
      controller: controller,
      readiness: .blocked
    )

    await model.refresh()

    #expect(model.status == .unavailable)
    #expect(!model.isAvailable)
    #expect(!model.canChange)
    #expect(model.readinessMessage == HexGatewayActivationReadiness.blocked.message)
    #expect(await controller.statusCallCount == 0)

    model.toggle()

    #expect(model.message == HexGatewayActivationReadiness.blocked.message)
    #expect(await controller.registerCallCount == 0)
  }

  @Test @MainActor
  func missingBundledHelperIsPresentedAsPending() async {
    let model = HexStartAtLoginModel(
      controller: FakeController(status: .notFound),
      readiness: .ready
    )
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

  private actor SpyController: HexGatewayLifecycleControlling {
    let currentStatus: HexGatewayLifecycleStatus
    private(set) var statusCallCount = 0
    private(set) var registerCallCount = 0

    init(status: HexGatewayLifecycleStatus) {
      currentStatus = status
    }

    func status() async -> HexGatewayLifecycleStatus {
      statusCallCount += 1
      return currentStatus
    }

    func register() async throws {
      registerCallCount += 1
    }

    func unregister() async throws {}
  }
}
