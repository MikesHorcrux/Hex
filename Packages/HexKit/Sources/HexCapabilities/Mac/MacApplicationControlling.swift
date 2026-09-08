import Foundation

public protocol MacApplicationControlling: Sendable {
  func runningApplications() async throws -> [MacApplicationSnapshot]
  func activateApplication(bundleIdentifier: String) async throws
    -> MacApplicationActivationResult
  func openURL(_ url: URL) async throws
}
