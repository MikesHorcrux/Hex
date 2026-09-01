@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation

public actor SystemMacAccessibilityController: MacAccessibilityControlling {
  public init() {}

  public func isTrusted(promptIfNeeded: Bool) async -> Bool {
    await MainActor.run {
      guard promptIfNeeded else {
        return AXIsProcessTrusted()
      }
      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
  }

  public func snapshot(
    bundleIdentifier: String,
    maximumDepth: Int,
    maximumElements: Int
  ) async throws -> MacAccessibilitySnapshot {
    try await MainActor.run {
      guard AXIsProcessTrusted() else {
        throw MacToolError.accessibilityPermissionRequired
      }
      let application = try Self.runningApplication(bundleIdentifier: bundleIdentifier)
      let root = AXUIElementCreateApplication(application.processIdentifier)
      let traversal = Self.traverse(
        root: root,
        maximumDepth: maximumDepth,
        maximumElements: maximumElements
      )
      return MacAccessibilitySnapshot(
        bundleIdentifier: bundleIdentifier,
        applicationName: application.localizedName ?? bundleIdentifier,
        processIdentifier: application.processIdentifier,
        elements: traversal.elements,
        isTruncated: traversal.isTruncated
      )
    }
  }

  public func perform(
    _ request: MacAccessibilityActionRequest
  ) async throws -> MacAccessibilityActionResult {
    try await MainActor.run {
      guard AXIsProcessTrusted() else {
        throw MacToolError.accessibilityPermissionRequired
      }
      let application = try Self.runningApplication(
        bundleIdentifier: request.bundleIdentifier
      )
      let root = AXUIElementCreateApplication(application.processIdentifier)
      let match = try Self.resolveElement(root: root, selector: request.selector)

      let error: AXError
      switch request.action {
      case .press:
        guard Self.actions(for: match.element).contains(kAXPressAction as String) else {
          throw MacToolError.accessibilityActionUnsupported
        }
        error = AXUIElementPerformAction(match.element, kAXPressAction as CFString)

      case .focus:
        error = AXUIElementSetAttributeValue(
          match.element,
          kAXFocusedAttribute as CFString,
          kCFBooleanTrue
        )

      case .setValue:
        guard let value = request.value else {
          throw MacToolError.invalidArguments
        }
        guard
          Self.stringAttribute(kAXSubroleAttribute as String, from: match.element)
            != (kAXSecureTextFieldSubrole as String)
        else {
          throw MacToolError.accessibilityActionUnsupported
        }
        error = AXUIElementSetAttributeValue(
          match.element,
          kAXValueAttribute as CFString,
          value as CFString
        )
      }
      guard error == .success else {
        throw MacToolError.accessibilityActionFailed
      }
      return MacAccessibilityActionResult(
        bundleIdentifier: request.bundleIdentifier,
        path: match.path,
        action: request.action
      )
    }
  }

  @MainActor
  private static func runningApplication(
    bundleIdentifier: String
  ) throws -> NSRunningApplication {
    guard
      let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).first(where: { !$0.isTerminated })
    else {
      throw MacToolError.applicationNotFound
    }
    return application
  }

  @MainActor
  private static func traverse(
    root: AXUIElement,
    maximumDepth: Int,
    maximumElements: Int
  ) -> (elements: [MacAccessibilityElementSnapshot], isTruncated: Bool) {
    var queue: [(element: AXUIElement, depth: Int, path: String)] = [(root, 0, "0")]
    var cursor = 0
    var elements: [MacAccessibilityElementSnapshot] = []
    elements.reserveCapacity(maximumElements)
    var isTruncated = false

    while cursor < queue.count {
      if elements.count >= maximumElements {
        isTruncated = true
        break
      }
      let node = queue[cursor]
      cursor += 1
      let children = children(of: node.element)
      elements.append(snapshot(element: node.element, path: node.path, childCount: children.count))
      if node.depth < maximumDepth {
        let remainingCapacity = max(maximumElements - queue.count, 0)
        if children.count > remainingCapacity {
          isTruncated = true
        }
        for (index, child) in children.enumerated().prefix(remainingCapacity) {
          queue.append((child, node.depth + 1, "\(node.path).\(index)"))
        }
      } else if !children.isEmpty {
        isTruncated = true
      }
    }
    return (elements, isTruncated)
  }

  @MainActor
  private static func resolveElement(
    root: AXUIElement,
    selector: MacAccessibilitySelector
  ) throws -> (element: AXUIElement, path: String) {
    var queue: [(element: AXUIElement, depth: Int, path: String)] = [(root, 0, "0")]
    var cursor = 0
    var matches: [(element: AXUIElement, path: String)] = []
    while cursor < queue.count, cursor < 2_048 {
      let node = queue[cursor]
      cursor += 1
      if matchesSelector(node.element, path: node.path, selector: selector) {
        matches.append((node.element, node.path))
      }
      guard node.depth < 16 else { continue }
      let remainingCapacity = max(2_048 - queue.count, 0)
      for (index, child) in children(of: node.element).enumerated().prefix(remainingCapacity) {
        queue.append((child, node.depth + 1, "\(node.path).\(index)"))
      }
    }
    if let occurrence = selector.occurrence {
      guard matches.indices.contains(occurrence) else {
        throw MacToolError.accessibilityElementNotFound
      }
      return matches[occurrence]
    }
    guard let match = matches.first else {
      throw MacToolError.accessibilityElementNotFound
    }
    guard matches.count == 1 else {
      throw MacToolError.accessibilityElementAmbiguous
    }
    return match
  }

  @MainActor
  private static func matchesSelector(
    _ element: AXUIElement,
    path: String,
    selector: MacAccessibilitySelector
  ) -> Bool {
    if let expected = selector.path, expected != path { return false }
    if let expected = selector.identifier,
      expected != stringAttribute(kAXIdentifierAttribute as String, from: element)
    {
      return false
    }
    if let expected = selector.role,
      expected != stringAttribute(kAXRoleAttribute as String, from: element)
    {
      return false
    }
    if let expected = selector.title,
      expected != stringAttribute(kAXTitleAttribute as String, from: element)
    {
      return false
    }
    return true
  }

  @MainActor
  private static func snapshot(
    element: AXUIElement,
    path: String,
    childCount: Int
  ) -> MacAccessibilityElementSnapshot {
    let role = stringAttribute(kAXRoleAttribute as String, from: element) ?? "AXUnknown"
    let subrole = stringAttribute(kAXSubroleAttribute as String, from: element)
    let isSecure = subrole == (kAXSecureTextFieldSubrole as String)
    let boundedActions = actions(for: element).compactMap(bounded).sorted()
    return MacAccessibilityElementSnapshot(
      path: path,
      role: role,
      subrole: subrole,
      title: bounded(stringAttribute(kAXTitleAttribute as String, from: element)),
      label: bounded(stringAttribute(kAXDescriptionAttribute as String, from: element)),
      value: isSecure
        ? nil : bounded(renderedValue(attribute: kAXValueAttribute as String, from: element)),
      identifier: bounded(stringAttribute(kAXIdentifierAttribute as String, from: element)),
      isEnabled: boolAttribute(kAXEnabledAttribute as String, from: element),
      isFocused: boolAttribute(kAXFocusedAttribute as String, from: element),
      actions: Array(boundedActions.prefix(64)),
      childCount: childCount
    )
  }

  @MainActor
  private static func children(of element: AXUIElement) -> [AXUIElement] {
    attribute(kAXChildrenAttribute as String, from: element) as? [AXUIElement] ?? []
  }

  @MainActor
  private static func actions(for element: AXUIElement) -> [String] {
    var value: CFArray?
    guard AXUIElementCopyActionNames(element, &value) == .success else {
      return []
    }
    return value as? [String] ?? []
  }

  @MainActor
  private static func stringAttribute(
    _ name: String,
    from element: AXUIElement
  ) -> String? {
    attribute(name, from: element) as? String
  }

  @MainActor
  private static func boolAttribute(
    _ name: String,
    from element: AXUIElement
  ) -> Bool? {
    (attribute(name, from: element) as? NSNumber)?.boolValue
  }

  @MainActor
  private static func renderedValue(
    attribute name: String,
    from element: AXUIElement
  ) -> String? {
    guard let value = attribute(name, from: element) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  @MainActor
  private static func attribute(
    _ name: String,
    from element: AXUIElement
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  private static func bounded(_ value: String?) -> String? {
    guard let value else { return nil }
    var result = ""
    var bytes = 0
    for character in value {
      let fragment = String(character)
      let next = bytes + fragment.utf8.count
      guard next <= 1_024 else { break }
      result.append(character)
      bytes = next
    }
    return result.isEmpty ? nil : result
  }
}
