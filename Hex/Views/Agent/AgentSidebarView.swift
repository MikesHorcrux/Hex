import Observation
import SwiftUI

struct AgentSidebarView: View {
  @Bindable var model: AgentWorkspaceModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("HEX")
          .font(.system(size: 28, weight: .bold, design: .rounded))
          .tracking(2)
        Text("First-agent control surface")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 10) {
        Label("Gateway", systemImage: "bolt.horizontal.circle")
          .font(.headline)
        HStack(spacing: 8) {
          Circle()
            .fill(connectionColor)
            .frame(width: 9, height: 9)
          Text(model.connectionState.label)
            .font(.subheadline.weight(.medium))
          Spacer()
          if model.connectionState == .connecting {
            ProgressView()
              .controlSize(.small)
          } else if model.connectionState == .connected {
            Button("Disconnect", action: model.disconnectFromControl)
              .buttonStyle(.hexSecondaryAction)
              .controlSize(.small)
          } else {
            Button("Connect", action: model.connectFromControl)
              .buttonStyle(.hexPrimaryAction)
              .controlSize(.small)
          }
        }
        Text(model.gatewaySummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        HStack {
          Label("Conversations", systemImage: "bubble.left.and.bubble.right")
            .font(.headline)
          Spacer()
          Button {
            model.newConversation()
          } label: {
            Image(systemName: "plus")
              .accessibilityLabel("New conversation")
          }
          .buttonStyle(.hexSecondaryAction)
          .controlSize(.small)
        }

        if model.isRestoringConversations {
          HStack(spacing: 7) {
            ProgressView()
              .controlSize(.small)
            Text("Restoring local history…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else if model.orderedConversations.isEmpty {
          Text("Your conversations will appear here after the first prompt.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(model.orderedConversations) { conversation in
                Button {
                  model.selectConversation(conversation.id)
                } label: {
                  HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bubble.left")
                      .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                      Text(conversation.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                      Text(conversation.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                  }
                  .padding(.horizontal, 8)
                  .padding(.vertical, 6)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                  conversation.id == model.selectedConversationID
                    ? Color.accentColor.opacity(0.14)
                    : Color.clear,
                  in: RoundedRectangle(cornerRadius: 7)
                )
                .accessibilityLabel(conversation.title)
                .accessibilityAddTraits(
                  conversation.id == model.selectedConversationID ? .isSelected : []
                )
              }
            }
          }
          .frame(maxHeight: 150)
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        Label("Model", systemImage: "cpu")
          .font(.headline)
        TextField("Model ID", text: $model.modelID)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("modelIDField")
        Text("The gateway composition supplies the provider and credentials.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      VStack(alignment: .leading, spacing: 9) {
        Label("Current run", systemImage: "waveform.path.ecg")
          .font(.headline)
        Text(model.runSummary)
          .font(.subheadline.weight(.medium))
        Text(model.activity)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 12)

      VStack(alignment: .leading, spacing: 5) {
        Label("Permissioned by design", systemImage: "checkmark.shield")
          .font(.subheadline.weight(.medium))
        Text("Tool requests pause here until you choose what Hex may do.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected:
      .green
    case .connecting:
      .orange
    case .disconnected:
      .secondary
    }
  }
}
