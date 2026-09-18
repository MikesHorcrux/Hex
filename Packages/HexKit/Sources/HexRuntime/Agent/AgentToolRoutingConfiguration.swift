import HexCore

/// Controls how the runtime exposes Hex's tool catalog to automatic model turns.
///
/// The host still owns the complete tool executor and authorization boundary. This configuration
/// only controls which schemas are sent to the model for a particular request. Explicit required
/// or named tool choices always bypass adaptive narrowing.
public struct AgentToolRoutingConfiguration: Codable, Equatable, Sendable {
  public let isEnabled: Bool
  public let largeContextThreshold: Int
  public let maximumToolsForCompactContext: Int
  public let maximumToolsForLargeContext: Int

  /// Legacy/default runtime behavior for directly constructed runtimes and durable payloads.
  /// Gateway compositions opt into the adaptive policy explicitly.
  public static let disabled = Self(isEnabled: false)
  public static let standard = Self()

  public init(
    isEnabled: Bool = true,
    largeContextThreshold: Int = 65_536,
    maximumToolsForCompactContext: Int = 24,
    maximumToolsForLargeContext: Int = 64
  ) {
    self.isEnabled = isEnabled
    self.largeContextThreshold = largeContextThreshold
    self.maximumToolsForCompactContext = maximumToolsForCompactContext
    self.maximumToolsForLargeContext = maximumToolsForLargeContext
  }

  func validate() throws {
    guard (1...16_777_216).contains(largeContextThreshold),
      (1...4_096).contains(maximumToolsForCompactContext),
      (1...4_096).contains(maximumToolsForLargeContext)
    else {
      throw AgentRuntimeError.invalidConfiguration("Invalid adaptive tool routing limits.")
    }
  }
}
