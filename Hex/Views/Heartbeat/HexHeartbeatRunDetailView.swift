import HexCore
import HexIPC
import SwiftUI

struct HexHeartbeatRunDetailView: View {
  @Bindable var model: HexHeartbeatRunDetailModel
  let scheduleRemoved: Bool
  @State private var selectedArtifact: ArtifactReference?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(model.run.scheduleName).font(.title3.bold()).textSelection(.enabled)
          Spacer()
          Button("Refresh result", systemImage: "arrow.clockwise") {
            Task { await model.refresh() }
          }
          .disabled(model.isLoading)
        }
        Text("Scheduled \(model.run.dueAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(.secondary)
        if scheduleRemoved {
          Text("Schedule removed · result retained").font(.caption).foregroundStyle(.secondary)
        }
        if let outcome = model.run.outcome {
          Text(
            "\(HexHeartbeatRunPresentation.status(model.run)) · \(outcome.completedAt.formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.callout)
          if let failure = outcome.failureMessage {
            Text(failure).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
          }
        }
        Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if let error = model.errorMessage {
          Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        }
      }.padding(18)
      Divider()
      if model.isLoading && !model.hasLoaded {
        ProgressView("Reading saved activity…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if model.pageStart > 0 || model.hasPartialAssistantText {
              Text(
                "This is one activity page, not the whole conversation. Text fragments may continue on adjacent pages; a saved complete reply replaces its fragments on this page."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
            if model.items.isEmpty {
              Text(
                model.hasLoaded
                  ? "No readable messages on this page. Earlier activity may contain the request or tool output."
                  : "Use Refresh result to read the saved run."
              )
              .foregroundStyle(.secondary).padding(.vertical, 20)
            }
            ForEach(model.items) { item in
              AgentConversationRowView(item: item, onOpenArtifact: { selectedArtifact = $0 })
            }
          }.padding(18).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
      }
      Divider()
      HStack {
        Button(model.previousPageTitle, systemImage: "chevron.left") {
          Task { await model.previousPage() }
        }
        .disabled(!model.canGoBack)
        Spacer()
        if model.isLoading { ProgressView().controlSize(.small) }
        Text(
          model.throughSequence > 0
            ? "Events \(model.pageStart + 1)–\(model.pageEnd) of \(model.throughSequence)"
            : "Read-only"
        )
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Spacer()
        Button("Next activity", systemImage: "chevron.right") { Task { await model.nextPage() } }
          .disabled(!model.canGoNext)
      }.padding(12)
    }
    .background(HexBrandPalette.canvas)
    .inspector(
      isPresented: Binding(
        get: { selectedArtifact != nil }, set: { if !$0 { selectedArtifact = nil } })
    ) {
      if let selectedArtifact {
        AgentArtifactPreviewView(reference: selectedArtifact, client: model.client)
          .id(selectedArtifact.id)
          .inspectorColumnWidth(min: 300, ideal: 390, max: 600)
      }
    }
    .task { await model.refresh() }
    .onChange(of: model.throughSequence) { _, sequence in
      if sequence == 0 { selectedArtifact = nil }
    }
  }
}
