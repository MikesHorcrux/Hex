import Observation

@MainActor
@Observable
final class HexStartAtLoginModel {
  private(set) var status: HexGatewayLifecycleStatus = .unknown
  private(set) var isUpdating = false
  private(set) var message: String?

  private let controller: any HexGatewayLifecycleControlling

  init(
    controller: any HexGatewayLifecycleControlling = HexSMAppServiceLifecycleController()
  ) {
    self.controller = controller
  }

  var isEnabled: Bool {
    status.isEnabled
  }

  var canChange: Bool {
    status.canChange && !isUpdating
  }

  var buttonTitle: String {
    isEnabled ? "Disable start at login" : "Enable start at login"
  }

  func refresh() async {
    status = await controller.status()
  }

  func toggle() {
    guard canChange else {
      if status == .notFound {
        message = "Start at login is pending the bundled gateway helper."
      }
      return
    }

    isUpdating = true
    message = nil
    let shouldEnable = !isEnabled
    Task { [weak self] in
      guard let self else { return }
      do {
        if shouldEnable {
          try await controller.register()
        } else {
          try await controller.unregister()
        }
        status = await controller.status()
        isUpdating = false
      } catch is CancellationError {
        isUpdating = false
      } catch {
        status = await controller.status()
        isUpdating = false
        message = error.localizedDescription
      }
    }
  }

  func dismissMessage() {
    message = nil
  }
}
