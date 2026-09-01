import Foundation
import Observation

@MainActor
@Observable
final class HexStartAtLoginModel {
  private(set) var status: HexGatewayLifecycleStatus
  private(set) var isUpdating = false
  private(set) var message: String?

  private let controller: any HexGatewayLifecycleControlling
  private let readiness: HexGatewayActivationReadiness

  init(
    controller: any HexGatewayLifecycleControlling = HexSMAppServiceLifecycleController(),
    readiness: HexGatewayActivationReadiness = .blocked
  ) {
    self.controller = controller
    self.readiness = readiness
    status = readiness.isReady ? .unknown : .unavailable
  }

  var isEnabled: Bool {
    readiness.isReady && status.isEnabled
  }

  var canChange: Bool {
    readiness.isReady && status.canChange && !isUpdating
  }

  var buttonTitle: String {
    isEnabled ? "Disable start at login" : "Enable start at login"
  }

  var isAvailable: Bool {
    readiness.isReady
  }

  var readinessMessage: String? {
    readiness.isReady ? nil : readiness.message
  }

  func refresh() async {
    guard readiness.isReady else {
      status = .unavailable
      message = readiness.message
      return
    }
    status = await controller.status()
    message = nil
  }

  func toggle() {
    guard readiness.isReady else {
      message = readiness.message
      return
    }
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
