import Foundation

public struct MacAccessibilitySnapshot: Equatable, Sendable {
  public let observationID: String
  public let bundleIdentifier: String
  public let applicationName: String
  public let processIdentifier: Int32
  public let elements: [MacAccessibilityElementSnapshot]
  public let isTruncated: Bool

  public init(
    bundleIdentifier: String,
    applicationName: String,
    processIdentifier: Int32,
    elements: [MacAccessibilityElementSnapshot],
    isTruncated: Bool,
    observationID: String = UUID().uuidString
  ) {
    self.observationID = observationID
    self.bundleIdentifier = bundleIdentifier
    self.applicationName = applicationName
    self.processIdentifier = processIdentifier
    self.elements = elements
    self.isTruncated = isTruncated
  }
}
