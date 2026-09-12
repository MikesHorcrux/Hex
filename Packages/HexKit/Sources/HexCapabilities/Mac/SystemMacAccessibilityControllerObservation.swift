import AppKit
@preconcurrency import ApplicationServices
import Dispatch
import Foundation

struct SystemMacAccessibilityControllerObservation {
  let bundleIdentifier: String
  let processIdentifier: Int32
  let launchDate: Date
  let capturedAt: UInt64
  let elements: [SystemMacAccessibilityControllerObservedElement]
}
