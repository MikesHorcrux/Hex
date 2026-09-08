import Foundation
import HexIPC
import Observation

@MainActor
@Observable
final class HexFolderAccessModel {
  private(set) var status: GatewayFolderAccessStatus?
  private(set) var message: String?
  private(set) var isChecking = false
  private(set) var hasRequestedCheck = false
  private let service: (any HexPermissionManaging)?
  private var generation = UUID()

  init(service: (any HexPermissionManaging)?) { self.service = service }

  func invalidate() {
    generation = UUID()
    status = nil
  }

  func refresh(ifPreviouslyRequested: Bool = false) async {
    guard !isChecking, !ifPreviouslyRequested || hasRequestedCheck else { return }
    hasRequestedCheck = true
    let expected = generation
    isChecking = true
    status = nil
    message = nil
    defer { isChecking = false }
    do {
      guard let service else {
        throw GatewayFailure(
          code: .transportUnavailable, message: "Connect to Hex Agent to check its folder access.")
      }
      let response = try await service.folderAccessStatus().validated()
      try Task.checkCancellation()
      guard generation == expected else { return }
      status = response
    } catch {
      guard generation == expected else { return }
      if !(error is CancellationError) { message = error.localizedDescription }
    }
  }
}
