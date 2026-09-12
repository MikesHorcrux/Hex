import Foundation

public enum ProcessSessionCommandAction: String, Codable, Sendable {
  case input, interrupt, eof, resize, stop
}
