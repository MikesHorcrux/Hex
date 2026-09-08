import ApplicationServices
import Foundation
import Testing

@testable import HexCapabilities

@Suite("Native Accessibility child read semantics")
@MainActor
struct MacAccessibilityChildrenReadTests {
  @Test
  func successfulEmptyArrayIsAConfirmedEmptyHierarchy() throws {
    let children = try SystemMacAccessibilityController.decodeChildren(
      value: [] as CFArray, error: .success, path: "0")
    #expect(children.isEmpty)
  }

  @Test
  func successfulArrayRetainsActualAXReferences() throws {
    // Creating an AX reference sends no message and reads no running application's UI.
    let element = AXUIElementCreateApplication(Int32.max)
    let children = try SystemMacAccessibilityController.decodeChildren(
      value: [element] as CFArray, error: .success, path: "0")
    #expect(children.count == 1)
    #expect(children.first.map { CFEqual($0, element) } == true)
  }

  @Test
  func transportAndInvalidElementFailuresCannotBecomeEmptyLeaves() {
    for error in [
      AXError.cannotComplete, .invalidUIElement, .notImplemented, .failure, .apiDisabled,
    ] {
      for path in ["0", "0.2.1"] {
        #expect(
          throws: MacAccessibilityReadError(
            elementPath: path, axErrorCode: error.rawValue, reason: .requestFailed)
        ) {
          try SystemMacAccessibilityController.decodeChildren(value: nil, error: error, path: path)
        }
      }
    }
  }

  @Test
  func absentLeafChildrenDoNotProveAnApplicationHierarchyIsEmpty() throws {
    for error in [AXError.attributeUnsupported, .noValue] {
      let leaf = try SystemMacAccessibilityController.decodeChildren(
        value: nil, error: error, path: "0.1")
      #expect(leaf.isEmpty)
      #expect(
        throws: MacAccessibilityReadError(
          elementPath: "0", axErrorCode: error.rawValue, reason: .childrenNotExposed)
      ) {
        try SystemMacAccessibilityController.decodeChildren(value: nil, error: error, path: "0")
      }
    }
  }

  @Test
  func successWithoutAnAXElementArrayIsIncomplete() {
    let malformedValues: [CFTypeRef?] = [nil, "not an array" as CFString, ["not AX"] as CFArray]
    for value in malformedValues {
      #expect(
        throws: MacAccessibilityReadError(
          elementPath: "0", axErrorCode: AXError.success.rawValue, reason: .invalidValue)
      ) {
        try SystemMacAccessibilityController.decodeChildren(
          value: value, error: .success, path: "0")
      }
    }
  }
}
