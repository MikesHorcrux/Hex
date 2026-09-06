import Foundation
import Observation

@MainActor
@Observable
final class HexStartAtLoginModel: HexResidentConfigurationReloading {
  private(set) var status: HexGatewayLifecycleStatus
  private(set) var isUpdating = false
  private(set) var message: String?

  private let controller: any HexGatewayLifecycleControlling
  private let readinessChecker: any HexGatewayActivationReadinessChecking
  private let loginItemsSettingsOpener: any HexLoginItemsSettingsOpening
  private let connectionResetter: (any HexResidentGatewayConnectionResetting)?
  private let onBecameReady: (@MainActor @Sendable () async -> Void)?
  private var hasReportedReady = false
  private var refreshID = UUID()
  private(set) var readiness = HexGatewayActivationReadiness.blocked

  init(
    controller: any HexGatewayLifecycleControlling = HexSMAppServiceLifecycleController(),
    readinessChecker: any HexGatewayActivationReadinessChecking =
      HexBlockedGatewayActivationChecker(),
    loginItemsSettingsOpener: any HexLoginItemsSettingsOpening =
      HexSMAppServiceLifecycleController(),
    connectionResetter: (any HexResidentGatewayConnectionResetting)? = nil,
    onBecameReady: (@MainActor @Sendable () async -> Void)? = nil
  ) {
    self.controller = controller
    self.readinessChecker = readinessChecker
    self.loginItemsSettingsOpener = loginItemsSettingsOpener
    self.connectionResetter = connectionResetter
    self.onBecameReady = onBecameReady
    status = .unavailable
  }

  var isEnabled: Bool {
    status.isEnabled
  }

  var canChange: Bool {
    guard !isUpdating else { return false }
    return switch status {
    case .enabled:
      true
    case .notRegistered, .notFound:
      readiness.isReady
    case .requiresApproval, .unknown, .unavailable:
      false
    }
  }

  var canRestart: Bool {
    !isUpdating && status == .enabled && readiness.isReady
  }

  var buttonTitle: String {
    isEnabled ? "Disable start at login" : "Enable start at login"
  }

  var isAvailable: Bool {
    readiness.isReady || status.isEnabled || status == .requiresApproval
  }

  var readinessMessage: String? {
    readiness.isReady || status == .requiresApproval ? nil : readiness.message
  }

  func refresh() async {
    guard !isUpdating else { return }
    let requestID = UUID()
    refreshID = requestID
    let lifecycleStatus = await controller.status()
    let observedReadiness = await readinessChecker.check()
    guard refreshID == requestID, !isUpdating else { return }
    status = lifecycleStatus
    readiness = observedReadiness
    switch lifecycleStatus {
    case .enabled:
      message = nil
    case .requiresApproval:
      message = "Approve Hex in System Settings before changing start at login."
    case .unknown, .notRegistered, .notFound, .unavailable:
      message = readiness.isReady ? nil : readiness.message
    }
    await reportReadyTransition()
  }

  func toggle() {
    guard !isUpdating else { return }
    refreshID = UUID()
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
        case .notRegistered, .notFound:
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
        case .unavailable:
          isUpdating = false
          return
        }
        status = await controller.status()
        await reportReadyTransition()
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

  /// Re-registers an enabled LaunchAgent after its launchd job becomes unreachable. macOS keeps
  /// the user's enabled choice separately from the running job, so `status == .enabled` alone does
  /// not prove the resident process can be reached. The explicit user action that calls this method
  /// is the mutation boundary.
  func restart() async {
    do { try await reloadEnabledService(reportDisabledService: true) } catch {
      message = error.localizedDescription
    }
  }

  /// Applies a completed settings save to the live resident process. A disabled service will read
  /// the settings on its next activation; an enabled service is disconnected and re-registered so
  /// launchd starts a fresh helper from the current app bundle and configuration.
  func reloadAfterConfigurationChange() async throws {
    try await reloadEnabledService(reportDisabledService: false)
  }

  private func reloadEnabledService(reportDisabledService: Bool) async throws {
    try Task.checkCancellation()
    guard !isUpdating else {
      throw HexResidentReloadError.unavailable(
        "Hex Agent is already being updated. Try saving again.")
    }
    isUpdating = true
    refreshID = UUID()
    message = nil
    defer { isUpdating = false }

    status = await controller.status()
    try Task.checkCancellation()
    readiness = await readinessChecker.check()
    try Task.checkCancellation()
    guard status == .enabled else {
      if reportDisabledService {
        message = "Hex Agent is not enabled. Activate it before trying to restart it."
      } else if status == .requiresApproval {
        message = "Approve Hex in System Settings before changing start at login."
      } else {
        message = readiness.isReady ? nil : readiness.message
      }
      if !reportDisabledService, status == .notRegistered || status == .notFound { return }
      throw HexResidentReloadError.unavailable(
        message ?? "Hex Agent is unavailable. Try saving again.")
    }
    guard readiness.isReady else {
      message = readiness.message
      throw HexResidentReloadError.unavailable(readiness.message)
    }

    do {
      await connectionResetter?.resetResidentGatewayConnection()
      try Task.checkCancellation()
      // SMAppService's async unregister completes only after the old job is safe to register again.
      // Once unregistered, finish the pair instead of stranding a previously enabled service.
      try await controller.unregister()
      try await controller.register()
      status = await controller.status()
      try Task.checkCancellation()
      guard status == .enabled else {
        message = "Hex Agent did not become enabled after restarting."
        throw HexResidentReloadError.unavailable(
          "Hex Agent did not become enabled after restarting.")
      }
    } catch is CancellationError {
      status = await controller.status()
      throw CancellationError()
    } catch {
      status = await controller.status()
      message = error.localizedDescription
      throw error
    }
  }

  func dismissMessage() {
    message = nil
  }

  /// An enabled registration and validated readiness justify one connection attempt, not a claim
  /// that XPC is reachable. Refreshes never repeatedly reconnect or mutate service registration.
  private func reportReadyTransition() async {
    let isReady = status == .enabled && readiness.isReady
    guard isReady else {
      hasReportedReady = false
      return
    }
    guard !hasReportedReady else { return }
    hasReportedReady = true
    await onBecameReady?()
  }

  func openLoginItemsSettings() async {
    guard status == .requiresApproval else { return }
    await loginItemsSettingsOpener.openLoginItemsSettings()
  }
}
