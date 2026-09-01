import Observation

@MainActor
@Observable
final class HexResidentGatewayModel {
  private(set) var status: HexResidentGatewayStatus = .unavailable
  private(set) var isUpdating = false
  private(set) var message: String?

  private let controller: any HexResidentGatewayControlling

  init(
    controller: any HexResidentGatewayControlling = HexUnavailableResidentGatewayController()
  ) {
    self.controller = controller
  }

  var canTogglePause: Bool {
    status.isAvailable && !isUpdating
  }

  var pauseButtonTitle: String {
    status.isPaused ? "Resume heartbeats" : "Pause heartbeats"
  }

  func refresh() async {
    do {
      status = try await controller.status()
      message = nil
    } catch is CancellationError {
      return
    } catch {
      status = .unavailable
      message = error.localizedDescription
    }
  }

  func togglePause() {
    guard !isUpdating else { return }
    guard status.isAvailable else {
      message = "Heartbeat controls are unavailable until the resident gateway is connected."
      return
    }

    isUpdating = true
    message = nil
    let target = !status.isPaused
    Task { [weak self] in
      guard let self else { return }
      do {
        if target {
          status = try await controller.pauseHeartbeats()
        } else {
          status = try await controller.resumeHeartbeats()
        }
        isUpdating = false
      } catch is CancellationError {
        isUpdating = false
      } catch {
        isUpdating = false
        message = error.localizedDescription
      }
    }
  }

  func dismissMessage() {
    message = nil
  }
}
