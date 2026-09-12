import ApplicationServices
import Foundation

extension SystemMacAccessibilityController {
  static func traverse(
    root: AXUIElement,
    maximumDepth: Int,
    maximumElements: Int
  ) throws -> (elements: [SystemMacAccessibilityControllerObservedElement], isTruncated: Bool) {
    var elements: [SystemMacAccessibilityControllerObservedElement] = []
    var windows: [(element: CFTypeRef, reference: String)] = []
    elements.reserveCapacity(maximumElements)
    let isTruncated = try MacAccessibilityTraversal.walk(
      root: root, maximumDepth: maximumDepth, maximumElements: maximumElements,
      children: { try children(of: $0, path: $1) },
      visit: { element, path, childCount in
        let window = observedWindow(of: element)
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
          element: element, path: path, childCount: childCount, windowReference: reference
        )
        elements.append(
          SystemMacAccessibilityControllerObservedElement(
            element: element, window: window, value: value))
      })
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
    var currentPath = "0"
    for part in parts.dropFirst() {
      try Task.checkCancellation()
      guard let index = Int(part), index >= 0 else {
        throw MacToolError.accessibilityElementNotFound
      }
      let currentChildren = try children(of: element, path: currentPath)
      guard currentChildren.indices.contains(index) else {
        throw MacToolError.accessibilityElementNotFound
      }
      element = currentChildren[index]
      currentPath += ".\(part)"
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

  static func children(of element: AXUIElement, path: String) throws -> [AXUIElement] {
    try Task.checkCancellation()
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
    try Task.checkCancellation()
    return try decodeChildren(value: value, error: error, path: path)
  }

  /// A missing child attribute is normal for a leaf. It does not establish that an application's
  /// entire hierarchy is empty. Transport/read failures at any depth must never masquerade as leaves.
  static func decodeChildren(value: CFTypeRef?, error: AXError, path: String) throws
    -> [AXUIElement]
  {
    switch error {
    case .success:
      guard let children = value as? [AXUIElement],
        children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
      else {
        throw MacAccessibilityReadError(
          elementPath: path, axErrorCode: error.rawValue, reason: .invalidValue)
      }
      return children
    case .attributeUnsupported, .noValue:
      guard path != "0" else {
        throw MacAccessibilityReadError(
          elementPath: path, axErrorCode: error.rawValue, reason: .childrenNotExposed)
      }
      return []
    default:
      throw MacAccessibilityReadError(
        elementPath: path, axErrorCode: error.rawValue, reason: .requestFailed)
    }
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
