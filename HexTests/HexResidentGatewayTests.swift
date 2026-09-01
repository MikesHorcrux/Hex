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
    #expect(
      model.message == "Heartbeat controls are unavailable until the resident gateway is connected."
    )
  }

  @Test @MainActor
  func injectedControllerCanPauseAndResume() async throws {
    let controller = FakeController(status: .idle)
    let model = HexResidentGatewayModel(controller: controller)
    await model.refresh()

    #expect(model.status == .idle)
    #expect(model.canTogglePause)
    #expect(model.pauseButtonTitle == "Pause heartbeats")

    model.togglePause()
    for _ in 0..<20 where model.status != .paused {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(model.status == .paused)
    #expect(model.pauseButtonTitle == "Resume heartbeats")
    #expect(await controller.lastRequestedPause == true)
  }

  @Test
  func liveClientReportsUnavailableBeforeWorkspaceConnection() async throws {
    let client = HexLiveAgentClient(
      configuration: HexDeveloperConfiguration(environment: [:]),
      route: .residentXPC(machServiceName: "com.example.hex.test")
    )

    #expect(try await client.status() == .unavailable)
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

    func pauseHeartbeats() async throws -> HexResidentGatewayStatus {
      lastRequestedPause = true
      currentStatus = .paused
      return currentStatus
    }

    func resumeHeartbeats() async throws -> HexResidentGatewayStatus {
      lastRequestedPause = false
      currentStatus = .idle
      return currentStatus
    }
  }
}
