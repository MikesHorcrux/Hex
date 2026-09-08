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
  func notFoundServiceWithReadyBundleCanRegister() async throws {
    let controller = SpyController(status: .notFound)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .ready)
    )
    await model.refresh()

    #expect(model.status == .notFound)
    #expect(model.status.label == "Not registered")
    #expect(model.canChange)

    model.toggle()
    try await waitForUpdate(model)

    #expect(await controller.registerCallCount == 1)
    #expect(model.status == .enabled)
    #expect(model.message == nil)
  }

  @Test @MainActor
  func notFoundServiceWithBlockedReadinessDoesNotRegister() async throws {
    let controller = SpyController(status: .notFound)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .blocked)
    )
    await model.refresh()

    #expect(!model.canChange)
    #expect(model.readinessMessage == HexGatewayActivationReadiness.blocked.message)

    model.toggle()
    try await waitForUpdate(model)

    #expect(await controller.registerCallCount == 0)
    #expect(model.message == HexGatewayActivationReadiness.blocked.message)
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

  @Test @MainActor
  func enabledButUnreachableServiceCanBeRestartedInRequiredOrder() async {
    let controller = SpyController(status: .enabled)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .ready)
    )
    await model.refresh()

    #expect(model.canRestart)

    await model.restart()

    #expect(await controller.lifecycleMutations == ["unregister", "register"])
    #expect(model.status == .enabled)
    #expect(model.message == nil)
    #expect(!model.isUpdating)
  }

  @Test @MainActor
  func restartFailsClosedWhenResidentConfigurationIsNotReady() async {
    let controller = SpyController(status: .enabled)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .blocked)
    )
    await model.refresh()

    #expect(!model.canRestart)
    #expect(model.readinessMessage == HexGatewayActivationReadiness.blocked.message)

    await model.restart()

    #expect(await controller.lifecycleMutations.isEmpty)
    #expect(model.status == .enabled)
    #expect(model.message == HexGatewayActivationReadiness.blocked.message)
  }

  @Test @MainActor
  func savedConfigurationResetsConnectionBeforeRestartingEnabledService() async throws {
    let events = LifecycleEvents()
    let controller = SpyController(status: .enabled, events: events)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .ready),
      connectionResetter: SpyConnectionResetter(events: events)
    )

    try await model.reloadAfterConfigurationChange()

    #expect(await events.values == ["reset-connection", "unregister", "register"])
    #expect(model.status == .enabled)
    #expect(model.message == nil)
  }

  @Test @MainActor
  func savedConfigurationDoesNotRegisterADisabledService() async throws {
    let controller = SpyController(status: .notRegistered)
    let model = HexStartAtLoginModel(
      controller: controller,
      readinessChecker: FixedReadinessChecker(value: .ready)
    )

    try await model.reloadAfterConfigurationChange()

    #expect(await controller.lifecycleMutations.isEmpty)
    #expect(model.status == .notRegistered)
    #expect(model.message == nil)
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

  private actor SpyController: HexGatewayLifecycleControlling {
    private(set) var currentStatus: HexGatewayLifecycleStatus
    private(set) var statusCallCount = 0
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var lifecycleMutations: [String] = []
    private let events: LifecycleEvents?

    init(status: HexGatewayLifecycleStatus, events: LifecycleEvents? = nil) {
      currentStatus = status
      self.events = events
    }

    func status() async -> HexGatewayLifecycleStatus {
      statusCallCount += 1
      return currentStatus
    }

    func register() async throws {
      registerCallCount += 1
      lifecycleMutations.append("register")
      await events?.append("register")
      currentStatus = .enabled
    }

    func unregister() async throws {
      unregisterCallCount += 1
      lifecycleMutations.append("unregister")
      await events?.append("unregister")
      currentStatus = .notRegistered
    }
  }

  private struct SpyConnectionResetter: HexResidentGatewayConnectionResetting {
    let events: LifecycleEvents

    func resetResidentGatewayConnection() async {
      await events.append("reset-connection")
    }
  }

  private actor LifecycleEvents {
    private(set) var values: [String] = []

    func append(_ value: String) {
      values.append(value)
    }
  }

  private actor SpySettingsOpener: HexLoginItemsSettingsOpening {
    private(set) var openCallCount = 0

    func openLoginItemsSettings() async {
      openCallCount += 1
    }
  }
}
