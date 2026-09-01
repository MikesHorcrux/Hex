import Testing

@testable import Hex

@Suite("Resident gateway controls")
struct HexResidentGatewayTests {
  @Test @MainActor
  func unavailableControlDoesNotPretendToPauseTheGateway() async {
    let model = HexResidentGatewayModel()
    await model.refresh()

    #expect(model.status == .unavailable)
    #expect(!model.canTogglePause)

    model.togglePause()

    #expect(model.status == .unavailable)
    #expect(model.message == "Pause/resume is pending resident gateway control IPC.")
  }

  @Test @MainActor
  func injectedControllerCanPauseAndResume() async throws {
    let controller = FakeController(status: .idle)
    let model = HexResidentGatewayModel(controller: controller)
    await model.refresh()

    #expect(model.status == .idle)
    #expect(model.canTogglePause)

    model.togglePause()
    for _ in 0..<20 where model.status != .paused {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(model.status == .paused)
    #expect(await controller.lastRequestedPause == true)
  }

  private actor FakeController: HexResidentGatewayControlling {
    private(set) var currentStatus: HexResidentGatewayStatus
    private(set) var lastRequestedPause: Bool?

    init(status: HexResidentGatewayStatus) {
      currentStatus = status
    }

    func status() async throws -> HexResidentGatewayStatus {
      currentStatus
    }

    func setPaused(_ paused: Bool) async throws -> HexResidentGatewayStatus {
      lastRequestedPause = paused
      currentStatus = paused ? .paused : .idle
      return currentStatus
    }
  }
}
