@preconcurrency import AppKit
import Foundation

extension SystemMacApplicationController: MacLocalURLControlling {
  public func openLocalURL(_ url: URL, bundleIdentifier: String) async throws
    -> MacApplicationSnapshot
  {
    try await Self.openPreview(url, bundleIdentifier: bundleIdentifier)
  }

  @MainActor
  private static func openPreview(_ url: URL, bundleIdentifier: String) async throws
    -> MacApplicationSnapshot
  {
    guard
      let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier)
    else { throw MacToolError.applicationNotFound }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<MacApplicationSnapshot, any Error>) in
      NSWorkspace.shared.open(
        [url], withApplicationAt: applicationURL, configuration: configuration
      ) {
        application, error in
        guard error == nil, let application else {
          continuation.resume(throwing: MacToolError.openURLFailed)
          return
        }
        continuation.resume(
          returning: MacApplicationSnapshot(
            bundleIdentifier: application.bundleIdentifier ?? bundleIdentifier,
            localizedName: application.localizedName ?? bundleIdentifier,
            processIdentifier: application.processIdentifier, isActive: application.isActive,
            isHidden: application.isHidden))
      }
    }
  }
}
