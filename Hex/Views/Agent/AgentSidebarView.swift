import Observation
import SwiftUI

struct AgentSidebarView: View {
  @Bindable var model: AgentWorkspaceModel
  @State private var conversationToDelete: AgentConversation?
  @State private var conversationToRename: AgentConversation?
  @State private var filter: AgentConversationListFilter = .conversations
  @State private var searchText = ""
  @State private var search = AgentConversationSearch()
  @State private var searchMatches: Set<UUID> = []
  @State private var completedSearchRequest: AgentConversationSearchRequest?
  @State private var searchError: String?
  @State private var organizationError: String?
  @State private var isOrganizing = false

  var body: some View {
    VStack(spacing: 0) {
      AgentSidebarBrandView(onNewConversation: newConversation)

      VStack(spacing: 10) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(HexBrandPalette.mutedInk)
          TextField("Search conversations", text: $searchText)
            .textFieldStyle(.plain)
            .accessibilityIdentifier("conversationSearchField")
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(HexBrandPalette.mutedInk)
            .accessibilityLabel("Clear conversation search")
          }
        }
        .font(.callout)
        .padding(8)
        .background(HexBrandPalette.hairline.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

        Picker("Conversation filter", selection: $filter) {
          ForEach(AgentConversationListFilter.allCases) { choice in
            Text(choice.title).tag(choice)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("conversationListFilter")

        if let selected = selectedArchivedConversation {
          HStack {
            Label("Archived", systemImage: "archivebox")
              .foregroundStyle(HexBrandPalette.mutedInk)
            Spacer(minLength: 4)
            Button("Unarchive") { setArchived(selected, archived: false) }
              .disabled(isOrganizing || !model.canOrganizeConversation(selected.id))
              .accessibilityIdentifier("unarchiveCurrentConversation")
          }
          .font(.caption)
        }

        if let organizationError {
          Text(organizationError)
            .font(.caption)
            .foregroundStyle(HexBrandPalette.warningInk)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("conversationOrganizationError")
        }
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 10)

      List(selection: conversationSelection) {
        Section {
          if model.isRestoringConversations {
            HStack(spacing: 8) {
              ProgressView()
                .controlSize(.small)
                .tint(HexBrandPalette.coral)
              Text("Restoring history…")
                .foregroundStyle(HexBrandPalette.mutedInk)
            }
          } else if isSearching {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Searching conversations…")
                .foregroundStyle(HexBrandPalette.mutedInk)
            }
          } else if visibleConversations.isEmpty {
            Text(emptyMessage)
              .font(.callout)
              .foregroundStyle(HexBrandPalette.mutedInk)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.vertical, 8)
          } else {
            ForEach(visibleConversations) { conversation in
              AgentSidebarConversationRow(
                conversation: conversation,
                canOrganize: !isOrganizing && model.canOrganizeConversation(conversation.id),
                canDelete: !isOrganizing && !model.isRunActive,
                onRename: { conversationToRename = conversation },
                onArchive: { setArchived(conversation, archived: !conversation.isArchived) },
                onDelete: { conversationToDelete = conversation }
              )
              .tag(conversation.id)
            }
          }
        } header: {
          Text(filter.sectionTitle)
            .font(.caption2.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(HexBrandPalette.mutedInk)
            .textCase(.uppercase)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(HexBrandPalette.sidebarTint)

      AgentSidebarStatusView(
        connectionState: model.connectionState,
        runSummary: model.runSummary
      )
    }
    .background(HexBrandPalette.sidebarTint)
    .task(id: searchRequest) {
      let request = searchRequest
      guard !request.query.isEmpty else {
        searchError = nil
        completedSearchRequest = nil
        searchMatches = []
        return
      }
      let snapshot = scopedConversations
      searchError = nil
      do {
        try await Task.sleep(for: .milliseconds(180))
        let matches = try await search.matchingConversationIDs(in: snapshot, query: request.query)
        try Task.checkCancellation()
        searchMatches = matches
        completedSearchRequest = request
      } catch is CancellationError {
        // A newer query owns the results. Never publish a cancelled snapshot.
      } catch {
        guard !Task.isCancelled else { return }
        searchError = "Conversation search could not finish. Change the search to try again."
        searchMatches = []
        completedSearchRequest = request
      }
    }
    .sheet(item: $conversationToRename) { conversation in
      AgentConversationRenameView(model: model, conversation: conversation)
    }
    .confirmationDialog(
      "Delete conversation?", isPresented: deletionConfirmation, presenting: conversationToDelete
    ) { conversation in
      Button("Delete Conversation", role: .destructive) {
        model.deleteConversation(conversation.id)
        conversationToDelete = nil
      }
    } message: { conversation in
      Text(
        "Delete “\(conversation.title)”? This removes its saved history and any unsaved output. This cannot be undone."
      )
    }
  }

  private var scopedConversations: [AgentConversation] {
    model.orderedConversations.filter(filter.includes)
  }

  private var searchRequest: AgentConversationSearchRequest {
    AgentConversationSearchRequest(
      query: searchText, conversations: scopedConversations,
      revision: model.conversationSearchRevision)
  }

  private var isSearching: Bool {
    !searchRequest.query.isEmpty && completedSearchRequest != searchRequest
  }

  private var visibleConversations: [AgentConversation] {
    guard !searchRequest.query.isEmpty else { return scopedConversations }
    guard completedSearchRequest == searchRequest else { return [] }
    return scopedConversations.filter { searchMatches.contains($0.id) }
  }

  private var selectedArchivedConversation: AgentConversation? {
    model.conversations.first { $0.id == model.selectedConversationID && $0.isArchived }
  }

  private var emptyMessage: String {
    if let searchError { return searchError }
    if !searchRequest.query.isEmpty { return "No matching conversations in \(filter.title)." }
    return filter == .archived
      ? "Archived conversations stay saved here. You can unarchive them anytime."
      : "Your conversations will appear here."
  }

  private func newConversation() {
    let previousSelection = model.selectedConversationID
    model.newConversation()
    if model.selectedConversationID != previousSelection {
      searchText = ""
      filter = .conversations
      organizationError = nil
    }
  }

  private func setArchived(_ conversation: AgentConversation, archived: Bool) {
    guard !isOrganizing else { return }
    organizationError = nil
    isOrganizing = true
    Task {
      let saved = await model.setConversationArchived(conversation.id, archived: archived)
      isOrganizing = false
      if !saved {
        organizationError =
          model.errorMessage ?? "The conversation could not be updated. Try again."
      }
    }
  }

  private var deletionConfirmation: Binding<Bool> {
    Binding(
      get: { conversationToDelete != nil },
      set: { if !$0 { conversationToDelete = nil } }
    )
  }

  private var conversationSelection: Binding<UUID?> {
    Binding(
      get: { model.selectedConversationID },
      set: { selection in
        guard let selection else { return }
        model.selectConversation(selection)
      }
    )
  }
}
