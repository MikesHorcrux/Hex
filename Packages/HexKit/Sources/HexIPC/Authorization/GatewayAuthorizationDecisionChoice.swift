import Foundation

/// The small, stable choice vocabulary the interactive app sends back to a resident gateway.
/// This stays in HexIPC so the app and the gateway never need to exchange an app-only enum or
/// concrete authorization provider type.
public enum GatewayAuthorizationDecisionChoice: String, Codable, Equatable, Sendable {
  case allowOnce
  case allowForSession
  case deny
}
