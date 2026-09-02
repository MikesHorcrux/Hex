import HexIPC
import Observation
import SwiftUI

struct HexHeartbeatManagementView: View {
  @Bindable var model: HexHeartbeatManagementModel
  @State private var isPresentingEditor = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Heartbeats")
            .font(.title2.weight(.semibold))
          Text("Let Hex check in on a schedule while the resident gateway is running.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          Task { await model.refresh() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)
      }

      if model.isPaused {
        Label(
          "All scheduled heartbeats are paused from the resident controls.",
          systemImage: "pause.circle"
        )
        .foregroundStyle(.secondary)
      }

      if let message = model.message {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(message)
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button("Dismiss") {
            model.dismissMessage()
          }
          .buttonStyle(.link)
        }
      }

      if model.schedules.isEmpty {
        ContentUnavailableView(
          "No heartbeats yet",
          systemImage: "calendar.badge.clock",
          description: Text("Add a schedule for Hex to run a personal check-in.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(model.schedules) { schedule in
            HexHeartbeatScheduleRow(
              schedule: schedule,
              isBusy: model.isBusy,
              onTogglePause: {
                Task { await model.togglePause(for: schedule) }
              },
              onRemove: {
                Task { await model.removeSchedule(id: schedule.id) }
              }
            )
            .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
            .listRowSeparator(.hidden)
          }
        }
        .listStyle(.plain)
      }

      HStack {
        if let limitMessage = model.scheduleLimitMessage {
          Text(limitMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          isPresentingEditor = true
        } label: {
          Label("Add heartbeat", systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canAddSchedule)
      }
    }
    .padding(20)
    .frame(minWidth: 560, minHeight: 420)
    .task {
      await model.refresh()
    }
    .sheet(isPresented: $isPresentingEditor) {
      HexHeartbeatScheduleEditorView { request in
        await model.addSchedule(request)
      }
    }
  }
}
