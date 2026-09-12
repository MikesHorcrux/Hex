import Foundation
import HexIPC
import Observation

@MainActor
@Observable
final class HexAccessibilityPermissionModel {
  private(set) var state = HexAccessibilityPermissionState.unchecked

  private let service: any HexAccessibilityPermissionServicing
  private var generation = UUID()

  init(service: any HexAccessibilityPermissionServicing) {
    self.service = service
  }

  var isBusy: Bool {
    state == .checking
  }

  var hasVerifiedGateway: Bool {
    state.hasVerifiedGateway
  }

  func invalidate() {
    generation = UUID()
    state = .unchecked
  }

  func refresh() async {
    guard !isBusy else { return }
    let expected = generation
    state = .checking
    do {
      let status = try await service.accessibilityPermissionStatus()
      try Task.checkCancellation()
      guard generation == expected else { return }
      state = status == .trusted ? .trusted : .notTrusted
    } catch is CancellationError {
      guard generation == expected else { return }
      state = .unchecked
    } catch {
      guard generation == expected else { return }
      state = Self.failureState(for: error)
    }
  }

  func request() async {
    guard !isBusy else { return }
    let expected = generation
    state = .checking
    do {
      // macOS permission prompting is asynchronous. Even if the immediate API result changes,
      // wait for a later explicit/foreground refresh before presenting access as granted.
      _ = try await service.requestAccessibilityPermission()
      try Task.checkCancellation()
      guard generation == expected else { return }
      state = .requestSent
    } catch is CancellationError {
      guard generation == expected else { return }
      state = .unchecked
    } catch {
      guard generation == expected else { return }
      state = Self.failureState(for: error)
    }
  }

  private static func failureState(for error: any Error) -> HexAccessibilityPermissionState {
    guard let failure = error as? GatewayFailure else {
      return .failed(error.localizedDescription)
    }
    switch failure.code {
    case .notConnected, .transportUnavailable, .disconnected:
      return .gatewayUnavailable
    case .incompatibleProtocolVersion:
      return .gatewayNeedsRestart
    default:
      return .failed(failure.message)
    }
  }
}
