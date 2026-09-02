import SwiftUI

struct AgentEmptyConversationView: View {
  var body: some View {
    ContentUnavailableView {
      Label("What can I help with?", systemImage: "sparkles")
    } description: {
      Text(
        "Ask Hex to inspect a project, research the web, or take an approved action on this Mac."
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}
