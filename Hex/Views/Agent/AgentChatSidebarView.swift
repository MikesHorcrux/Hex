import HexCore
import SwiftUI

struct AgentChatSidebarView: View {
  @Bindable var model: AgentChatWorkspaceModel
  @Environment(\.openSettings) private var openSettings
  @AppStorage("hex.settings.section") private var settingsSection = HexSettingsSection.general
  @State private var showsSearch = false
  @FocusState private var searchIsFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        HexAppIconView(size: 32)
        Text("Hex").font(.title3.weight(.semibold))
        Spacer()
      }
      .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 22)

      VStack(spacing: 3) {
        sidebarButton("New conversation", icon: "plus") { model.select(nil) }
          .keyboardShortcut("n", modifiers: .command)
          .disabled(model.isSubmitting || model.pending != nil)
        sidebarButton("Search", icon: "magnifyingglass") {
          showsSearch = true
          searchIsFocused = true
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        sidebarButton("Automations", icon: "bolt") {
          settingsSection = .heartbeats
          openSettings()
        }
      }
      .padding(.horizontal, 10)

      if showsSearch || !model.search.isEmpty {
        TextField("Search conversations", text: $model.search)
          .textFieldStyle(.roundedBorder)
          .focused($searchIsFocused)
          .padding(.horizontal, 16).padding(.top, 12)
          .onSubmit { model.filterChanged() }
          .onExitCommand {
            model.search = ""
            showsSearch = false
            model.filterChanged()
          }
          .task(id: model.search) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            model.filterChanged()
          }
      }

      HStack {
        Text(model.showsArchived ? "Archived" : model.search.isEmpty ? "Recent" : "Results")
          .font(.caption).foregroundStyle(HexBrandPalette.mutedInk)
        Spacer()
        Menu("Conversation filters", systemImage: "line.3.horizontal.decrease") {
          Toggle("Show archived", isOn: $model.showsArchived)
          Button("Refresh") { Task { await model.refresh() } }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .labelStyle(.iconOnly)
        .help("Filter and refresh conversations")
      }
      .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 6)
      .onChange(of: model.showsArchived) { _, _ in model.filterChanged() }

      List(
        selection: Binding(get: { model.selectedID }, set: { if let id = $0 { model.select(id) } })
      ) {
        ForEach(model.conversations, id: \.id) { conversation in
          Text(conversation.title)
            .font(.body).lineLimit(1)
            .padding(.vertical, 7)
            .tag(conversation.id)
            .listRowBackground(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.selectedID == conversation.id ? HexBrandPalette.softCoral : .clear)
            )
            .help(conversation.title)
        }
        if model.nextConversation != nil {
          Button("More conversations") { Task { await model.refresh(more: true) } }
        }
      }
      .listStyle(.sidebar).scrollContentBackground(.hidden)
      .overlay {
        if model.conversations.isEmpty {
          Text(
            model.isLoading
              ? "Loading conversations…"
              : model.search.isEmpty ? "Your conversations appear here." : "No conversations found"
          )
          .font(.callout).foregroundStyle(HexBrandPalette.mutedInk)
          .multilineTextAlignment(.center).padding(20)
        }
      }
      .disabled(model.isSubmitting || model.pending != nil)

      SettingsLink {
        Label("Settings", systemImage: "gearshape")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10).contentShape(Rectangle())
      }
      .buttonStyle(.plain).padding(10)
    }
    .foregroundStyle(HexBrandPalette.ink)
    .background(HexBrandPalette.sidebarTint)
  }

  private func sidebarButton(_ title: String, icon: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Label(title, systemImage: icon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
