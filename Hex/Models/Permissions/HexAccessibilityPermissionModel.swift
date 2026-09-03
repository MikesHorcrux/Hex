import Foundation
import HexIPC
import Observation

@MainActor
@Observable
final class HexAccessibilityPermissionModel {
  private(set) var state = HexAccessibilityPermissionState.unchecked

  private let service: any HexAccessibilityPermissionServicing

  init(service: any HexAccessibilityPermissionServicing) {
    self.service = service
  }

  var isBusy: Bool {
    state == .checking
  }

  var hasVerifiedGateway: Bool {
    state.hasVerifiedGateway
  }

  func refresh() async {
    guard !isBusy else { return }
    state = .checking
    do {
      let status = try await service.accessibilityPermissionStatus()
      state = status == .trusted ? .trusted : .notTrusted
    } catch is CancellationError {
      state = .unchecked
    } catch {
      state = Self.failureState(for: error)
    }
  }

  func request() async {
    guard !isBusy else { return }
    state = .checking
    do {
      // macOS permission prompting is asynchronous. Even if the immediate API result changes,
      // wait for a later explicit/foreground refresh before presenting access as granted.
      _ = try await service.requestAccessibilityPermission()
      state = .requestSent
    } catch is CancellationError {
      state = .unchecked
    } catch {
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
    default:
      return .failed(failure.message)
    }
  }
}
