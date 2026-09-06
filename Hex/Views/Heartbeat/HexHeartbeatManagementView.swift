import HexIPC
import Observation
import SwiftUI

struct HexHeartbeatManagementView: View {
  @Bindable var model: HexHeartbeatManagementModel
  let suppressAutomaticRefresh: Bool
  @State private var isPresentingEditor = false
  @State private var isPresentingHistory = false

  init(
    model: HexHeartbeatManagementModel,
    suppressAutomaticRefresh: Bool = false
  ) {
    self.model = model
    self.suppressAutomaticRefresh = suppressAutomaticRefresh
  }

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
        Button("Run history", systemImage: "clock.arrow.circlepath") {
          model.history.show()
          isPresentingHistory = true
        }
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

      if model.isLoading && model.schedules.isEmpty {
        ProgressView("Loading schedules…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !model.isAvailable && model.schedules.isEmpty {
        ContentUnavailableView(
          "Resident gateway unavailable",
          systemImage: "antenna.radiowaves.left.and.right.slash",
          description: Text(
            "Connect to the resident gateway to view or manage heartbeat schedules."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.schedules.isEmpty {
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
              },
              onViewResults: {
                model.history.show(scheduleID: schedule.id, name: schedule.name)
                isPresentingHistory = true
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
    .task {
      guard !suppressAutomaticRefresh else { return }
      await model.refresh()
    }
    .sheet(isPresented: $isPresentingEditor) {
      HexHeartbeatScheduleEditorView { request in
        await model.addSchedule(request)
      }
    }
    .sheet(isPresented: $isPresentingHistory) {
      HexHeartbeatRunHistoryView(
        model: model.history,
        currentScheduleIDs: model.isAvailable ? Set(model.schedules.map(\.id)) : nil)
    }
  }
}
