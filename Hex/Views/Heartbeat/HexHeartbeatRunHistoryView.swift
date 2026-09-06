import Foundation
import HexIPC
import SwiftUI

struct HexHeartbeatRunHistoryView: View {
  @Bindable var model: HexHeartbeatRunHistoryModel
  let currentScheduleIDs: Set<UUID>?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Run history").font(.title2.bold()).foregroundStyle(HexBrandPalette.ink)
          Text(model.filterName ?? "Saved background work, including removed schedules")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        if model.scheduleID != nil {
          Button("All schedules") {
            model.show()
            Task { await model.refresh() }
          }
        }
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
          .disabled(model.isLoading)
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(20)
      Divider()
      HSplitView {
        VStack(spacing: 0) {
          if let error = model.errorMessage {
            Text(error).font(.callout).foregroundStyle(.orange).padding(12)
          }
          if model.isLoading && !model.hasLoaded {
            ProgressView("Loading saved runs…").frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if model.runs.isEmpty {
            ContentUnavailableView(
              model.hasLoaded ? "No saved runs yet" : "Saved runs unavailable",
              systemImage: "clock.arrow.circlepath",
              description: Text(
                model.hasLoaded
                  ? "Results appear here after scheduled work is recorded. Removing a schedule does not remove its retained history."
                  : "Connect to Hex Agent, then refresh. Nothing will be run again."))
          } else {
            List(selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
              ForEach(
                model.runs.map { (id: HexHeartbeatRunHistoryModel.identity($0), run: $0) }, id: \.id
              ) { entry in
                HexHeartbeatRunRow(run: entry.run).tag(entry.id)
              }
            }
            .listStyle(.sidebar)
          }
          HStack {
            Button("Newer", systemImage: "chevron.left") { Task { await model.loadNewer() } }
              .disabled(!model.canGoBack)
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Older", systemImage: "chevron.right") { Task { await model.loadOlder() } }
              .disabled(model.nextCursor == nil || model.isLoading)
          }.padding(12)
        }
        .frame(minWidth: 270, idealWidth: 320, maxWidth: 390)
        if let detail = model.detail {
          HexHeartbeatRunDetailView(
            model: detail,
            scheduleRemoved: currentScheduleIDs.map { !$0.contains(detail.run.scheduleID) } ?? false
          )
          .id(detail.id)
          .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ContentUnavailableView(
            "Select a saved run", systemImage: "text.bubble",
            description: Text(
              "Read Hex's answer and saved tool output without starting another run.")
          )
          .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .tint(HexBrandPalette.coral)
    .frame(minWidth: 900, idealWidth: 1_100, minHeight: 620, idealHeight: 760)
    .task { if !model.hasLoaded { await model.refresh() } }
  }
}
