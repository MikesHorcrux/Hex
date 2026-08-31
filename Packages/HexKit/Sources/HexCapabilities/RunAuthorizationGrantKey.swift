import HexCore

struct RunAuthorizationGrantKey: Hashable, Sendable {
  let runID: AgentRunID
  let grantKey: AuthorizationGrantKey
}
