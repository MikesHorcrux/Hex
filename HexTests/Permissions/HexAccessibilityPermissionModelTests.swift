import HexIPC
import Testing

@testable import Hex

@Suite("Accessibility permission model")
struct HexAccessibilityPermissionModelTests {
  @Test @MainActor
  func replyFromAnInvalidatedAgentCannotRestoreAGreenPermissionState() async throws {
    let service = SuspendedPermissionService()
    let model = HexAccessibilityPermissionModel(service: service)
    let refresh = Task { await model.refresh() }
    for _ in 0..<200 {
      if await service.isWaiting { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await service.isWaiting)
    model.invalidate()
    await service.complete()
    await refresh.value
    #expect(model.state == .unchecked)
    #expect(!model.hasVerifiedGateway)
  }

  @Test @MainActor
  func requestWaitsForALaterRefreshBeforeReportingGranted() async {
    let service = PermissionService(status: .notTrusted, requestStatus: .trusted)
    let model = HexAccessibilityPermissionModel(service: service)

    await model.refresh()
    #expect(model.state == .notTrusted)
    #expect(model.hasVerifiedGateway)

    await model.request()
    #expect(model.state == .requestSent)

    await service.setStatus(.trusted)
    await model.refresh()
    #expect(model.state == .trusted)
  }

  @Test @MainActor
  func unavailableGatewayIsNotPresentedAsDeniedPermission() async {
    let model = HexAccessibilityPermissionModel(service: UnavailablePermissionService())

    await model.refresh()

    #expect(model.state == .gatewayUnavailable)
    #expect(!model.hasVerifiedGateway)
  }

  @Test @MainActor
  func staleGatewayProtocolIsPresentedAsRestartable() async {
    let model = HexAccessibilityPermissionModel(service: StalePermissionService())

    await model.refresh()

    #expect(model.state == .gatewayNeedsRestart)
    #expect(model.state.canRepairByRestartingGateway)
    #expect(!model.hasVerifiedGateway)
  }

  private actor PermissionService: HexAccessibilityPermissionServicing {
    private var status: GatewayAccessibilityPermissionStatus
    private let requestStatus: GatewayAccessibilityPermissionStatus

    init(
      status: GatewayAccessibilityPermissionStatus,
      requestStatus: GatewayAccessibilityPermissionStatus
    ) {
      self.status = status
      self.requestStatus = requestStatus
    }

    func accessibilityPermissionStatus() -> GatewayAccessibilityPermissionStatus {
      status
    }

    func requestAccessibilityPermission() -> GatewayAccessibilityPermissionStatus {
      requestStatus
    }

    func setStatus(_ status: GatewayAccessibilityPermissionStatus) {
      self.status = status
    }
  }

  private actor SuspendedPermissionService: HexAccessibilityPermissionServicing {
    private var continuation: CheckedContinuation<GatewayAccessibilityPermissionStatus, Never>?
    var isWaiting: Bool { continuation != nil }
    func accessibilityPermissionStatus() async -> GatewayAccessibilityPermissionStatus {
      await withCheckedContinuation { continuation = $0 }
    }
    func requestAccessibilityPermission() -> GatewayAccessibilityPermissionStatus { .notTrusted }
    func complete() {
      continuation?.resume(returning: .trusted)
      continuation = nil
    }
  }

  private struct UnavailablePermissionService: HexAccessibilityPermissionServicing {
    func accessibilityPermissionStatus() throws -> GatewayAccessibilityPermissionStatus {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The resident gateway is unavailable."
      )
    }

    func requestAccessibilityPermission() throws -> GatewayAccessibilityPermissionStatus {
      throw GatewayFailure(
        code: .transportUnavailable,
        message: "The resident gateway is unavailable."
      )
    }
  }

  private struct StalePermissionService: HexAccessibilityPermissionServicing {
    func accessibilityPermissionStatus() throws -> GatewayAccessibilityPermissionStatus {
      throw GatewayFailure(
        code: .incompatibleProtocolVersion,
        message: "The resident gateway protocol is stale."
      )
    }

    func requestAccessibilityPermission() throws -> GatewayAccessibilityPermissionStatus {
      throw GatewayFailure(
        code: .incompatibleProtocolVersion,
        message: "The resident gateway protocol is stale."
      )
    }
  }
}
