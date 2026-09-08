import ApplicationServices
import Foundation

extension SystemMacAccessibilityController {
  static func traverse(
    root: AXUIElement,
    maximumDepth: Int,
    maximumElements: Int
  ) -> (elements: [ObservedElement], isTruncated: Bool) {
    var queue: [(element: AXUIElement, depth: Int, path: String)] = [(root, 0, "0")]
    var cursor = 0
    var elements: [ObservedElement] = []
    var windows: [(element: CFTypeRef, reference: String)] = []
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
      let window = observedWindow(of: node.element)
      let reference: String?
      if let window {
        if let known = windows.first(where: { CFEqual($0.element, window) }) {
          reference = known.reference
        } else {
          let newReference = UUID().uuidString
          windows.append((window, newReference))
          reference = newReference
        }
      } else {
        reference = nil
      }
      let value = snapshot(
        element: node.element, path: node.path, childCount: children.count,
        windowReference: reference
      )
      elements.append(ObservedElement(element: node.element, window: window, value: value))
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

  static func resolveElement(
    root: AXUIElement,
    selector: MacAccessibilitySelector
  ) throws -> (element: AXUIElement, path: String) {
    guard let path = selector.path else { throw MacToolError.accessibilityElementNotFound }
    let parts = path.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.first == "0", parts.count <= 13 else {
      throw MacToolError.accessibilityElementNotFound
    }
    var element = root
    for part in parts.dropFirst() {
      try Task.checkCancellation()
      guard let index = Int(part), index >= 0 else {
        throw MacToolError.accessibilityElementNotFound
      }
      let currentChildren = children(of: element)
      guard currentChildren.indices.contains(index) else {
        throw MacToolError.accessibilityElementNotFound
      }
      element = currentChildren[index]
    }
    guard matchesSelector(element, path: path, selector: selector),
      selector.occurrence == nil || selector.occurrence == 0
    else { throw MacToolError.accessibilityElementNotFound }
    return (element, path)
  }

  static func matchesSelector(
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

  static func snapshot(
    element: AXUIElement,
    path: String,
    childCount: Int,
    windowReference: String? = nil
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
      childCount: childCount,
      windowReference: windowReference
    )
  }

  static func children(of element: AXUIElement) -> [AXUIElement] {
    attribute(kAXChildrenAttribute as String, from: element) as? [AXUIElement] ?? []
  }

  static func actions(for element: AXUIElement) -> [String] {
    var value: CFArray?
    guard AXUIElementCopyActionNames(element, &value) == .success else {
      return []
    }
    return value as? [String] ?? []
  }

  static func stringAttribute(
    _ name: String,
    from element: AXUIElement
  ) -> String? {
    attribute(name, from: element) as? String
  }

  static func boolAttribute(
    _ name: String,
    from element: AXUIElement
  ) -> Bool? {
    (attribute(name, from: element) as? NSNumber)?.boolValue
  }

  static func renderedValue(
    attribute name: String,
    from element: AXUIElement
  ) -> String? {
    guard let value = attribute(name, from: element) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  static func attribute(
    _ name: String,
    from element: AXUIElement
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }

  static func bounded(_ value: String?) -> String? {
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

  static func observedWindow(of element: AXUIElement) -> CFTypeRef? {
    if stringAttribute(kAXRoleAttribute as String, from: element) == (kAXWindowRole as String) {
      return element
    }
    guard let window = attribute(kAXWindowAttribute as String, from: element),
      CFGetTypeID(window) == AXUIElementGetTypeID()
    else { return nil }
    return window
  }

  static func sameWindow(_ first: CFTypeRef?, _ second: CFTypeRef?) -> Bool {
    switch (first, second) {
    case (nil, nil): true
    case (.some(let first), .some(let second)): CFEqual(first, second)
    default: false
    }
  }

  static func sameMeaning(
    _ first: MacAccessibilityElementSnapshot, _ second: MacAccessibilityElementSnapshot
  ) -> Bool {
    // Focus may move to Hex during human approval. Identity and the actionable content must match.
    first.path == second.path && first.role == second.role && first.subrole == second.subrole
      && first.title == second.title && first.label == second.label && first.value == second.value
      && first.identifier == second.identifier && first.isEnabled == second.isEnabled
      && first.actions == second.actions && first.childCount == second.childCount
  }
}
