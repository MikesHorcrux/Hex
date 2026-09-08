import HexCore
import SwiftUI

struct AgentChatSidebarView: View {
  @Bindable var model: AgentChatWorkspaceModel
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Conversations").font(.title2.bold())
        Spacer()
        Button("Refresh conversations", systemImage: "arrow.clockwise") {
          Task { await model.refresh() }
        }
        .labelStyle(.iconOnly)
      }.padding()
      TextField("Search conversations", text: $model.search)
        .textFieldStyle(.roundedBorder).padding(.horizontal)
        .onSubmit { model.filterChanged() }
      Toggle("Archived", isOn: $model.showsArchived).toggleStyle(.checkbox)
        .padding(.horizontal).padding(.vertical, 8)
        .onChange(of: model.showsArchived) { _, _ in model.filterChanged() }
      List(
        selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })
      ) {
        ForEach(model.conversations, id: \.id) { conversation in
          Text(conversation.title).lineLimit(2).padding(.vertical, 4).tag(conversation.id)
        }
        if model.nextConversation != nil {
          Button("More conversations") { Task { await model.refresh(more: true) } }
        }
      }.listStyle(.sidebar).disabled(model.isSubmitting || model.pending != nil)
    }
  }
}
