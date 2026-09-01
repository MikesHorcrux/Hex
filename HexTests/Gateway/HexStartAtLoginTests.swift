import Testing

@testable import Hex

@Suite("Start at login")
struct HexStartAtLoginTests {
  @Test @MainActor
  func blockedReadinessPreventsRegistrationButObservesLifecycle() async throws {
    let controller = SpyController(status: .notRegistered)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .blocked)
    )

    await model.refresh()

    #expect(model.status == .notRegistered)
    #expect(!model.isAvailable)
    #expect(!model.canChange)
    #expect(model.readinessMessage == HexGatewayActivationReadiness.blocked.message)
    #expect(await controller.statusCallCount == 1)

    model.toggle()
    try await waitForUpdate(model)

    #expect(model.message == HexGatewayActivationReadiness.blocked.message)
    #expect(await controller.registerCallCount == 0)
  }

  @Test @MainActor
  func missingBundledHelperIsPresentedAsPending() async throws {
    let model = HexStartAtLoginModel(
      controller: FakeController(status: .notFound),
      readinessChecker: FixedReadinessChecker(value: .ready)
    )
    await model.refresh()

    #expect(model.status == .notFound)
    #expect(!model.canChange)

    model.toggle()
    try await waitForUpdate(model)

    #expect(model.message == "Start at login is pending the bundled gateway helper.")
  }

  @Test @MainActor
  func approvalStatusShowsGuidanceWithoutRegistering() async throws {
    let controller = SpyController(status: .requiresApproval)
    let opener = SpySettingsOpener()
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .ready),
      loginItemsSettingsOpener: opener
    )

    await model.refresh()
    #expect(!model.canChange)

    model.toggle()
    try await waitForUpdate(model)

    #expect(
      model.message == "Approve Hex in System Settings before changing start at login."
    )
    #expect(await controller.registerCallCount == 0)

    await model.openLoginItemsSettings()
    #expect(await opener.openCallCount == 1)
  }

  @Test @MainActor
  func blockedReadinessStillAllowsDisablingAnEnabledService() async throws {
    let controller = SpyController(status: .enabled)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .blocked)
    )

    await model.refresh()

    #expect(model.isEnabled)
    #expect(model.canChange)
    #expect(model.buttonTitle == "Disable start at login")

    model.toggle()
    for _ in 0..<20 where model.isUpdating {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(await controller.unregisterCallCount == 1)
    #expect(model.status == .notRegistered)
  }

  private struct FixedReadinessChecker: HexGatewayActivationReadinessChecking {
    let value: HexGatewayActivationReadiness

    func check() async -> HexGatewayActivationReadiness {
      value
    }
  }

  @MainActor
  private func waitForUpdate(_ model: HexStartAtLoginModel) async throws {
    for _ in 0..<100 {
      if !model.isUpdating {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Start-at-login operation did not finish within the test budget.")
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
    private(set) var currentStatus: HexGatewayLifecycleStatus
    private(set) var statusCallCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

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

    func unregister() async throws {
      unregisterCallCount += 1
      currentStatus = .notRegistered
    }
  }

  private actor SpySettingsOpener: HexLoginItemsSettingsOpening {
    private(set) var openCallCount = 0

    func openLoginItemsSettings() async {
      openCallCount += 1
    }
  }
}
