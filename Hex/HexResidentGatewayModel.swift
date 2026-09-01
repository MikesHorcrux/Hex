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
    status.isPaused ? "Resume agent" : "Pause agent"
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
      message = "Pause/resume is pending resident gateway control IPC."
      return
    }

    isUpdating = true
    message = nil
    let target = !status.isPaused
    Task { [weak self] in
      guard let self else { return }
      do {
        status = try await controller.setPaused(target)
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
