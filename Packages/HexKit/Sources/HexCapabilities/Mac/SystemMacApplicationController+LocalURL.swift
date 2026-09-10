@preconcurrency import AppKit
import Foundation

extension SystemMacApplicationController: MacLocalURLControlling {
  public func openLocalURL(_ url: URL, bundleIdentifier: String) async throws {
    try await Self.openPreview(url, bundleIdentifier: bundleIdentifier)
  }

  @MainActor
  private static func openPreview(_ url: URL, bundleIdentifier: String) async throws {
    guard
      let applicationURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: bundleIdentifier)
    else { throw MacToolError.applicationNotFound }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      NSWorkspace.shared.open(
        [url], withApplicationAt: applicationURL, configuration: configuration
      ) {
        application, error in
        guard error == nil, application != nil else {
          continuation.resume(throwing: MacToolError.openURLFailed)
          return
        }
        continuation.resume()
      }
    }
  }
}
