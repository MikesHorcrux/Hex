import Foundation
import HexCore

public enum GatewayTaskAction: Codable, Equatable, Sendable {
  case pause, resume, cancel
  case steer(String)
  /// An explicit user observation/decision. Original uncertain receipts remain untouched.
  case reconcile(String)
}
