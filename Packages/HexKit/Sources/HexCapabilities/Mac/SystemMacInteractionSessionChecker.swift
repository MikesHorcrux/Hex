import CoreGraphics
import Foundation

/// Reads local WindowServer session availability without requesting permissions or changing state.
public struct SystemMacInteractionSessionChecker: Sendable {
  public init() {}

  public func status() -> MacInteractionSessionState {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
      return .unavailable
    }
    return Self.classify(
      isOnConsole: session[kCGSessionOnConsoleKey as String] as? Bool,
      loginComplete: session[kCGSessionLoginDoneKey as String] as? Bool,
      screenIsLocked: session["CGSSessionScreenIsLocked"] as? Bool)
  }

  /// The public console/login flags establish an available GUI session, not an unlocked screen.
  /// WindowServer also reports `CGSSessionScreenIsLocked` while locked; that runtime signal is not
  /// an SDK guarantee and may be absent. `.available` means an available console with no reported
  /// lock. Exact process, window and element checks remain required immediately before dispatch.
  public static func classify(
    isOnConsole: Bool?, loginComplete: Bool?, screenIsLocked: Bool?
  ) -> MacInteractionSessionState {
    if screenIsLocked == true { return .locked }
    guard isOnConsole == true, loginComplete == true else { return .unavailable }
    return .available
  }
}
