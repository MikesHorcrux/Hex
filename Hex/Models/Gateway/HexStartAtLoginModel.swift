import Foundation
import Observation

@MainActor
@Observable
final class HexStartAtLoginModel {
  private(set) var status: HexGatewayLifecycleStatus
  private(set) var isUpdating = false
  private(set) var message: String?

  private let controller: any HexGatewayLifecycleControlling
  private let readinessChecker: any HexGatewayActivationReadinessChecking
  private let loginItemsSettingsOpener: any HexLoginItemsSettingsOpening
  private(set) var readiness = HexGatewayActivationReadiness.blocked

  init(
    controller: any HexGatewayLifecycleControlling = HexSMAppServiceLifecycleController(),
    readinessChecker: any HexGatewayActivationReadinessChecking =
      HexBlockedGatewayActivationChecker(),
    loginItemsSettingsOpener: any HexLoginItemsSettingsOpening =
      HexSMAppServiceLifecycleController()
  ) {
    self.controller = controller
    self.readinessChecker = readinessChecker
    self.loginItemsSettingsOpener = loginItemsSettingsOpener
    status = .unavailable
  }

  var isEnabled: Bool {
    status.isEnabled
  }

  var canChange: Bool {
    guard !isUpdating else { return false }
    switch status {
    case .enabled:
      true
    case .notRegistered:
      readiness.isReady
    case .requiresApproval, .unknown, .notFound, .unavailable:
      false
    }
  }

  var buttonTitle: String {
    isEnabled ? "Disable start at login" : "Enable start at login"
  }

  var isAvailable: Bool {
    readiness.isReady || status.isEnabled || status == .requiresApproval
  }

  var readinessMessage: String? {
    readiness.isReady || status.isEnabled || status == .requiresApproval ? nil : readiness.message
  }

  func refresh() async {
    let lifecycleStatus = await controller.status()
    status = lifecycleStatus
    readiness = await readinessChecker.check()
    switch lifecycleStatus {
    case .enabled:
      message = nil
    case .requiresApproval:
      message = "Approve Hex in System Settings before changing start at login."
    case .unknown, .notRegistered, .notFound, .unavailable:
      message = readiness.isReady ? nil : readiness.message
    }
  }

  func toggle() {
    guard !isUpdating else { return }
    isUpdating = true
    message = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        status = await controller.status()
        readiness = await readinessChecker.check()
        switch status {
        case .enabled:
          try await controller.unregister()
        case .notRegistered:
          guard readiness.isReady else {
            message = readiness.message
            isUpdating = false
            return
          }
          try await controller.register()
        case .requiresApproval:
          message = "Approve Hex in System Settings before changing start at login."
          isUpdating = false
          return
        case .unknown:
          isUpdating = false
          return
        case .notFound:
          message = "Start at login is pending the bundled gateway helper."
          isUpdating = false
          return
        case .unavailable:
          isUpdating = false
          return
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

  func openLoginItemsSettings() async {
    guard status == .requiresApproval else { return }
    await loginItemsSettingsOpener.openLoginItemsSettings()
  }
}
