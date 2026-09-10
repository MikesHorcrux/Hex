import Foundation

/// Open an already validated loopback preview in one explicitly selected application.
public protocol MacLocalURLControlling: Sendable {
  func openLocalURL(_ url: URL, bundleIdentifier: String) async throws -> MacApplicationSnapshot
}
