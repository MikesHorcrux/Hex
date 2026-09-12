@preconcurrency import AppKit
import Foundation

public actor SystemMacApplicationController: MacApplicationControlling {
  public init() {}

  public func runningApplications() async throws -> [MacApplicationSnapshot] {
    await MainActor.run {
      NSWorkspace.shared.runningApplications
        .compactMap(Self.snapshot)
        .sorted {
          let nameOrder = $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName)
          if nameOrder == .orderedSame {
            return $0.bundleIdentifier < $1.bundleIdentifier
          }
          return nameOrder == .orderedAscending
        }
    }
  }

  public func activateApplication(
    bundleIdentifier: String
  ) async throws -> MacApplicationActivationResult {
    try await MainActor.run {
      if let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).first(where: { !$0.isTerminated }) {
        _ = application.unhide()
        guard application.activate(options: [.activateAllWindows]) else {
          throw MacToolError.activationFailed
        }
        return MacApplicationActivationResult(
          bundleIdentifier: bundleIdentifier,
          wasRunning: true
        )
      }

      guard
        let applicationURL = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: bundleIdentifier
        )
      else {
        throw MacToolError.applicationNotFound
      }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(
        at: applicationURL,
        configuration: configuration,
        completionHandler: nil
      )
      return MacApplicationActivationResult(
        bundleIdentifier: bundleIdentifier,
        wasRunning: false
      )
    }
  }

  public func openURL(_ url: URL) async throws {
    try await MainActor.run {
      guard NSWorkspace.shared.open(url) else {
        throw MacToolError.openURLFailed
      }
    }
  }

  @MainActor
  private static func snapshot(
    _ application: NSRunningApplication
  ) -> MacApplicationSnapshot? {
    guard
      !application.isTerminated,
      let bundleIdentifier = application.bundleIdentifier,
      let localizedName = application.localizedName
    else {
      return nil
    }
    return MacApplicationSnapshot(
      bundleIdentifier: bundleIdentifier,
      localizedName: localizedName,
      processIdentifier: application.processIdentifier,
      isActive: application.isActive,
      isHidden: application.isHidden
    )
  }
}
