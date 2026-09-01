import Foundation

/// The bounded lifecycle state returned by resident gateway control operations.
///
/// Pausing is deliberately scoped to scheduled heartbeats. It does not cancel or interrupt an
/// interactive task that is already running.
public enum GatewayResidentStatus: String, Codable, Equatable, Sendable {
  case unavailable
  case idle
  case active
  case paused
}
