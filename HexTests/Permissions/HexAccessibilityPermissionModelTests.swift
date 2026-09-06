import HexIPC
import Testing

@testable import Hex

@Suite("Accessibility permission model")
struct HexAccessibilityPermissionModelTests {
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
