/// Looks up existing execution evidence only. An inspector must never admit or retry a run.
public protocol HexHeartbeatRunInspecting: Sendable {
  func inspect(_ lease: HexHeartbeatLease) async throws -> HexHeartbeatRunInspection
}
