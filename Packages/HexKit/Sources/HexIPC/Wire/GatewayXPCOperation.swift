import Foundation

/// Operations carried by the Hex XPC boundary. The payload for every operation is a bounded
/// `GatewayWireCodec` Data value; XPC never receives an unbounded Codable object graph.
public enum GatewayXPCOperation: String, Codable, Hashable, Sendable {
  case handshake
  case startRun
  case cancelRun
  case recoverRun
  case readRunHistory
  case readArtifact
  case availableModels
  case toolServerHealth
  case refreshToolServer
  case submitAuthorizationDecision
  case approvalInbox
  case revokeSessionGrant
  case folderAccessStatus
  case accessibilityPermissionStatus
  case requestAccessibilityPermission
  case screenControlPermissionStatus
  case requestScreenControlPermission
  case status
  case pauseHeartbeats
  case resumeHeartbeats
  case listHeartbeats
  case listHeartbeatRuns
  case addHeartbeat
  case removeHeartbeat
  case pauseHeartbeat
  case resumeHeartbeat
  case subscribeEvents
  case cancelSubscription
  case disconnect
}
