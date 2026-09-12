import Foundation

public protocol WebAddressValidating: Sendable {
  func validate(_ url: URL) async throws
}
