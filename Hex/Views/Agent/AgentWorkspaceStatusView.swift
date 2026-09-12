import SwiftUI

/// Observe history/title changes here rather than invalidating the whole transcript hierarchy
/// for every canonical history watermark. Transcript rendering has its own coalesced snapshot.
struct AgentWorkspaceStatusView: View {
  let model: AgentWorkspaceModel

  var body: some View {
    AgentWorkspaceHeaderView(
      conversationTitle: model.selectedConversationTitle ?? "New conversation",
      activity: model.activity,
      connectionState: model.connectionState,
      runState: model.runState
    )
  }
}
