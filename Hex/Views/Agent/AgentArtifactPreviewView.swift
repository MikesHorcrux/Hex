import Foundation
import HexCore
import SwiftUI

struct AgentArtifactPreviewView: View {
  @State private var model: AgentArtifactPreviewModel

  init(reference: ArtifactReference, client: any HexAgentClient) {
    _model = State(initialValue: AgentArtifactPreviewModel(reference: reference, client: client))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Saved output")
        .font(.headline)
      Text(
        ByteCountFormatter.string(fromByteCount: model.reference.byteCount, countStyle: .file)
          + " · " + (model.reference.isComplete ? "Complete capture" : "Partial capture")
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      Text(model.reference.mediaType)
        .font(.caption)
        .foregroundStyle(.secondary)

      if let error = model.errorMessage {
        Text(error).font(.callout).foregroundStyle(.red)
        Button("Try again") { Task { await model.load() } }
          .disabled(model.isLoading)
      }
      HStack {
        Button("Previous", systemImage: "chevron.left") {
          Task { await model.previousPage() }
        }
        .disabled(!model.canGoBack)
        Spacer()
        if model.isLoading { ProgressView().controlSize(.small) }
        Button("Next", systemImage: "chevron.right") {
          Task { await model.nextPage() }
        }
        .disabled(model.nextOffset == nil || model.isLoading)
      }
      Text(
        "Bytes \(model.offset)–\(model.offset + Int64(model.displayedByteCount)) of \(model.reference.byteCount)"
      )
      .font(.caption.monospacedDigit())
      Text(model.encodingLabel).font(.caption2).foregroundStyle(.secondary)
      ScrollView([.horizontal, .vertical]) {
        Text(
          model.text.isEmpty
            ? (model.isLoading ? "Loading…" : "No output on this page.") : model.text
        )
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(10)
      .background(.background, in: RoundedRectangle(cornerRadius: 8))
      Text("Output ID: \(model.reference.id.uuidString)")
        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .padding(16)
    .task { await model.load() }
  }
}
