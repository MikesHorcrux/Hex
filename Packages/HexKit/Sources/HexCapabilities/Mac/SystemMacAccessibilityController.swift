import AppKit
// The SDK exposes the immutable AX prompt option key as an unannotated C global.
@preconcurrency import ApplicationServices
import Dispatch
import Foundation

/// Retains native AX identities on the main actor; public values crossing the boundary are Sendable.
@MainActor
public final class SystemMacAccessibilityController: MacAccessibilityControlling {
  private let now: @Sendable () -> UInt64
  private let sessionState: @Sendable () -> MacInteractionSessionState
  private var observations: [String: SystemMacAccessibilityControllerObservation] = [:]

  public nonisolated init(
    now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    sessionState: @escaping @Sendable () -> MacInteractionSessionState = {
      SystemMacInteractionSessionChecker().status()
    }
  ) {
    self.now = now
    self.sessionState = sessionState
  }

  public func isTrusted(promptIfNeeded: Bool) async -> Bool {
    guard promptIfNeeded else { return AXIsProcessTrusted() }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  public func snapshot(
    bundleIdentifier: String,
    maximumDepth: Int,
    maximumElements: Int
  ) async throws -> MacAccessibilitySnapshot {
    // A failed re-observation must not leave an older native action receipt usable for this app.
    observations = observations.filter {
      $0.value.bundleIdentifier != bundleIdentifier && isFresh($0.value.capturedAt)
    }
    try requireAvailable()
    guard (0...12).contains(maximumDepth), (1...512).contains(maximumElements) else {
      throw MacToolError.invalidArguments
    }
    let application = try Self.runningApplication(bundleIdentifier: bundleIdentifier)
    guard let launchDate = application.launchDate else {
      throw MacToolError.accessibilityObservationFailed
    }
    let root = AXUIElementCreateApplication(application.processIdentifier)
    guard Self.stringAttribute(kAXRoleAttribute as String, from: root) != nil else {
      throw MacToolError.accessibilityObservationFailed
    }
    let capturedAt = now()
    let traversal = try Self.traverse(
      root: root, maximumDepth: maximumDepth, maximumElements: maximumElements
    )
    try requireAvailable()
    let snapshot = MacAccessibilitySnapshot(
      bundleIdentifier: bundleIdentifier,
      applicationName: application.localizedName ?? bundleIdentifier,
      processIdentifier: application.processIdentifier,
      elements: traversal.elements.map(\.value), isTruncated: traversal.isTruncated
    )
    guard observations.count < 64 else { throw MacToolError.authorizationStateUnavailable }
    observations[snapshot.observationID] = SystemMacAccessibilityControllerObservation(
      bundleIdentifier: bundleIdentifier, processIdentifier: application.processIdentifier,
      launchDate: launchDate, capturedAt: capturedAt, elements: traversal.elements
    )
    return snapshot
  }

  public func perform(
    _ request: MacAccessibilityActionRequest
  ) async throws -> MacAccessibilityActionResult {
    // Consume before any failure: an interrupted or uncertain action must never reuse this receipt.
    guard let observation = observations.removeValue(forKey: request.observationID) else {
      throw MacToolError.accessibilityObservationStale
    }
    try requireAvailable()
    guard observation.bundleIdentifier == request.bundleIdentifier,
      isFresh(observation.capturedAt), let path = request.selector.path,
      let captured = observation.elements.first(where: { $0.value.path == path })
    else { throw MacToolError.accessibilityObservationStale }
    guard let application = try? Self.runningApplication(bundleIdentifier: request.bundleIdentifier)
    else { throw MacToolError.accessibilityObservationStale }
    guard application.processIdentifier == observation.processIdentifier,
      application.launchDate == observation.launchDate
    else { throw MacToolError.accessibilityObservationStale }
    let root = AXUIElementCreateApplication(application.processIdentifier)
    let match: (element: AXUIElement, path: String)
    do {
      match = try Self.resolveElement(root: root, selector: request.selector)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MacAccessibilityReadError {
      throw error
    } catch {
      throw MacToolError.accessibilityObservationStale
    }
    let currentChildren = try Self.children(of: match.element, path: match.path)
    guard CFEqual(captured.element, match.element),
      Self.sameWindow(captured.window, Self.observedWindow(of: match.element)),
      Self.sameMeaning(
        captured.value,
        Self.snapshot(
          element: match.element, path: match.path,
          childCount: currentChildren.count
        )
      )
    else { throw MacToolError.accessibilityObservationStale }

    let error: AXError
    switch request.action {
    case .press, .confirm:
      let actionName = request.action == .confirm ? kAXConfirmAction : kAXPressAction
      guard Self.actions(for: match.element).contains(actionName as String) else {
        throw MacToolError.accessibilityActionUnsupported
      }
      try requireAvailable()
      error = AXUIElementPerformAction(match.element, actionName as CFString)
    case .focus:
      try requireAvailable()
      error = AXUIElementSetAttributeValue(
        match.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
      )
    case .setValue:
      guard let value = request.value else { throw MacToolError.invalidArguments }
      guard
        Self.stringAttribute(kAXSubroleAttribute as String, from: match.element)
          != (kAXSecureTextFieldSubrole as String)
      else { throw MacToolError.accessibilityActionUnsupported }
      try requireAvailable()
      error = AXUIElementSetAttributeValue(
        match.element, kAXValueAttribute as CFString, value as CFString
      )
    }
    // AX errors may arrive after delivery; they do not prove that the action had no effect.
    guard error == .success else { throw MacToolError.accessibilityActionOutcomeUnknown }
    return MacAccessibilityActionResult(
      bundleIdentifier: request.bundleIdentifier, path: match.path, action: request.action,
      observationID: request.observationID, windowReference: captured.value.windowReference
    )
  }

  private func requireAvailable() throws {
    try Task.checkCancellation()
    try sessionState().requireAvailable()
    guard AXIsProcessTrusted() else { throw MacToolError.accessibilityPermissionRequired }
  }

  private func isFresh(_ capturedAt: UInt64) -> Bool {
    let current = now()
    return current >= capturedAt && current - capturedAt < 60_000_000_000
  }

  private static func runningApplication(bundleIdentifier: String) throws -> NSRunningApplication {
    let applications = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).filter { !$0.isTerminated }
    guard let application = applications.first else { throw MacToolError.applicationNotFound }
    guard applications.count == 1 else { throw MacToolError.accessibilityObservationFailed }
    return application
  }

}
