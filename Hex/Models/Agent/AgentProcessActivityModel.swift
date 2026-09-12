import Foundation
import HexCore
import HexIPC
import Observation

@MainActor
@Observable
final class AgentProcessActivityModel {
  private(set) var sessions: [ProcessSessionRecord] = []

  func observe(client: any HexGatewayProcessSessionClient, conversationID: UUID) async {
    sessions = []
    await AgentWorkspaceRefreshLoop(wait: { try await Task.sleep(for: .seconds(2)) }).run {
      let response = try await client.processSession(
        .list(conversationID: conversationID, before: nil, limit: 50))
      try Task.checkCancellation()
      self.sessions = response.sessions
    }
  }
}
