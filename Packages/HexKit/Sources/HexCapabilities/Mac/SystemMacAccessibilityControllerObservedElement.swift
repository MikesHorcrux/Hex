import AppKit
@preconcurrency import ApplicationServices
import Dispatch
import Foundation

struct SystemMacAccessibilityControllerObservedElement {
  let element: AXUIElement
  let window: CFTypeRef?
  let value: MacAccessibilityElementSnapshot
}
