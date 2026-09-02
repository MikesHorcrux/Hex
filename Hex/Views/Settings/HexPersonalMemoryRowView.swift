import HexPersonality
import SwiftUI

struct HexPersonalMemoryRowView: View {
  let memory: PersonalMemoryRecord
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: memory.isPinned ? "pin.fill" : "brain")
          .foregroundStyle(memory.isPinned ? .orange : .secondary)
        Text(memory.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Label(kindLabel, systemImage: "tag")
        Label(sourceLabel, systemImage: "person.crop.circle")
        Label(memory.scope.rawValue, systemImage: "scope")
          .font(.caption.monospaced())
        Spacer(minLength: 4)
        Text(memory.updatedAt, format: .dateTime.month().day().year())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        Button("Edit", action: onEdit)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("hexPersonalMemoryEditButton-\(memory.id.rawValue)")
        Button("Delete", role: .destructive, action: onDelete)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("hexPersonalMemoryDeleteButton-\(memory.id.rawValue)")
      }
    }
    .padding(.vertical, 5)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("hexPersonalMemoryRow-\(memory.id.rawValue)")
  }

  private var kindLabel: String {
    switch memory.kind {
    case .preference:
      "Preference"
    case .fact:
      "Fact"
    case .relationship:
      "Relationship"
    case .projectContext:
      "Project context"
    }
  }

  private var sourceLabel: String {
    switch memory.source {
    case .explicitUserStatement:
      "You told Hex"
    case .explicitUserCorrection:
      "You corrected Hex"
    case .userApprovedSuggestion:
      "You approved a suggestion"
    }
  }
}
