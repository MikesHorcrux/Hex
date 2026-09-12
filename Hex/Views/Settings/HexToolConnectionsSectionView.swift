import HexIPC
import SwiftUI

struct HexToolConnectionsSectionView: View {
  @Bindable var model: HexToolConnectionsModel
  @Bindable var workspace: AgentWorkspaceModel
  let suppressAutomaticRefresh: Bool

  var body: some View {
    Section {
      if !model.isSupported {
        Text("Live tool connections are unavailable in this preview or gateway route.")
          .foregroundStyle(.secondary)
      } else if workspace.connectionState != .connected || model.needsReconnect {
        Text("Connect to Hex Agent to see the tools loaded by the running agent.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button(
          workspace.connectionState == .connecting
            ? "Connecting to Hex Agent…" : "Connect to Hex Agent"
        ) {
          Task {
            if model.needsReconnect, workspace.connectionState == .connected {
              await workspace.disconnect()
            }
            await workspace.connect()
            model.connectionChanged(workspace.connectionState)
            await model.refresh()
          }
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(workspace.isRunActive || workspace.connectionState == .connecting)
      } else {
        if model.isLoading {
          ProgressView("Reading tool status…")
            .controlSize(.small)
        }
        if model.hasLoaded, model.servers.isEmpty {
          Text(
            "No tool servers are enabled in the running agent. Enable tools below and save to apply them."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        ForEach(model.servers, id: \.serverID) { server in
          HexToolConnectionRowView(
            status: server,
            isChecking: model.checkingServerIDs.contains(server.serverID),
            notice: model.rowNotices[server.serverID],
            canCheck: model.canCheckConnections && !workspace.isRunActive,
            onCheck: {
              model.isRunActive = workspace.isRunActive
              model.checkConnection(serverID: server.serverID)
            },
            onStopWaiting: { model.cancelCheck(serverID: server.serverID) }
          )
        }
        Button("Refresh status") {
          Task { await model.refresh() }
        }
        .buttonStyle(.hexSecondaryAction)
        .disabled(model.isLoading)
      }
      if let notice = model.notice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if workspace.isRunActive {
        Text(
          "Finish the current task before checking tool connections. Reading status does not interrupt it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } header: {
      Text("Running agent connections")
    } footer: {
      Text(
        "This is the running agent's last reported tool catalog, not your unsaved choices below. Check connection requests a fresh tool list. Connected does not grant Mac access or verify a task succeeded."
      )
    }
    .onChange(of: workspace.connectionState) { _, state in
      model.connectionChanged(state)
    }
    .onChange(of: workspace.isRunActive, initial: true) { _, isActive in
      model.isRunActive = isActive
    }
    .task(id: workspace.connectionState) {
      model.connectionChanged(workspace.connectionState)
      guard !suppressAutomaticRefresh else { return }
      await model.refresh()
    }
  }
}
