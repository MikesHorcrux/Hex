import HexCore
import HexIPC
import SwiftUI

struct AgentTaskListView: View {
  @Bindable var model: AgentTaskWorkspaceModel
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Tasks").font(.title2.bold())
        Spacer()
        Button("Refresh tasks", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
          .labelStyle(.iconOnly)
      }.padding()
      ScrollViewReader { proxy in
        List(
          selection: Binding(
            get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })
        ) {
          ForEach(model.tasks.sorted { $0.createdAt > $1.createdAt }) { task in
            VStack(alignment: .leading, spacing: 5) {
              Text(task.title).lineLimit(2)
              Text(task.phase.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 4).tag(task.id).id(task.id)
          }
          if model.nextPage != nil {
            Button("More tasks") { Task { await model.refresh(more: true) } }
          }
        }.scrollContentBackground(.hidden)
          .onChange(of: model.selectedID) { _, id in
            if let id { proxy.scrollTo(id, anchor: .top) }
          }
      }
    }.background(HexBrandPalette.sidebarTint)
  }
}
