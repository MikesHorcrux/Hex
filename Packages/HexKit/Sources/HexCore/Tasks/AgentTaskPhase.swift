import Foundation

public enum AgentTaskPhase: String, Codable, Sendable {
  case queued, running, pausing, cancelling, paused, waiting, blocked, completed, cancelled
  public var isTerminal: Bool { self == .completed || self == .cancelled }
}
