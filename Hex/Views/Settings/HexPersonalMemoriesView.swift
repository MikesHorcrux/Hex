import HexPersonality
import Observation
import SwiftUI

struct HexPersonalMemoriesView: View {
  @Bindable var model: HexPersonalMemoriesModel

  var body: some View {
    Group {
      Section {
        LabeledContent("Scope") {
          Text(model.scope.rawValue)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .accessibilityIdentifier("hexPersonalMemoriesScopeValue")
        }

        Text(
          "Showing only durable memories in this scope. Other scopes are intentionally not mixed into this list."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if model.isLoading {
          HStack {
            ProgressView()
              .controlSize(.small)
            Text("Loading personal memories…")
              .foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("hexPersonalMemoriesLoading")
        }

        memoryContent

        if let errorMessage = model.errorMessage {
          HexInlineNoticeView(
            message: errorMessage,
            systemImage: "exclamationmark.triangle.fill",
            tint: .orange
          )
          .accessibilityIdentifier("hexPersonalMemoriesError")
        }

        if let statusMessage = model.statusMessage {
          HexInlineNoticeView(
            message: statusMessage,
            systemImage: "checkmark.circle.fill",
            tint: HexBrandPalette.successInk
          )
          .accessibilityIdentifier("hexPersonalMemoriesStatus")
        }

        HStack {
          Button("Try Again") {
            Task {
              await model.reload()
            }
          }
          .buttonStyle(.hexSecondaryAction)
          .accessibilityIdentifier("hexPersonalMemoriesRetryButton")
          .disabled(model.isLoading || model.isSaving)

          Spacer()

          if model.canEdit && !model.isEditorPresented {
            Button("Add memory", action: model.beginAdding)
              .buttonStyle(.hexPrimaryAction)
              .accessibilityIdentifier("hexPersonalMemoriesAddButton")
          }
        }
      } header: {
        Text("Personal memories")
      } footer: {
        Text(
          "Memories are durable, user-managed records. Each row keeps its scope, kind, and source visible so Hex never presents inferred data as a user statement."
        )
      }
      .accessibilityIdentifier("hexPersonalMemoriesView")

      if model.isEditorPresented {
        HexPersonalMemoryEditorView(model: model)
      }
    }
    .task {
      await model.load()
    }
  }

  @ViewBuilder
  private var memoryContent: some View {
    switch model.state {
    case .idle, .loading:
      EmptyView()
    case .empty:
      ContentUnavailableView(
        "No saved memories",
        systemImage: "brain",
        description: Text(
          "Add a memory when you want Hex to retain something across conversations."
        )
      )
      .accessibilityIdentifier("hexPersonalMemoriesEmptyState")
    case .loaded:
      ForEach(model.memories, id: \.id) { memory in
        HexPersonalMemoryRowView(
          memory: memory,
          onEdit: {
            model.beginEditing(memory)
          },
          onDelete: {
            Task {
              await model.delete(memory)
            }
          }
        )
      }
    case .corrupted(let message), .unavailable(let message), .failed(let message):
      HexInlineNoticeView(
        message: message,
        systemImage: model.state.isUnavailable ? "nosign" : "exclamationmark.triangle",
        tint: model.state.isUnavailable ? HexBrandPalette.mutedInk : .orange
      )
      .accessibilityIdentifier("hexPersonalMemoriesStateMessage")
    }
  }
}
