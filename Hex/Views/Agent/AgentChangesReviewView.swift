import HexCore
import SwiftUI

struct AgentChangesReviewView: View {
  let review: WorkspaceChangesReview?
  let refresh: () -> Void
  let earlier: () -> Void
  let openPatch: (String, Int) -> Void
  @State private var section = "unstaged"
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Changes for this request").font(.headline)
        Spacer()
        Button("Refresh", action: refresh)
      }
      if let review {
        Text(review.explanation).font(.caption).foregroundStyle(.secondary)
        if review.current?.previewTruncated == true || review.baseline?.previewTruncated == true {
          Text("Git preview truncated. Inspect the affected files before accepting a large change.")
            .font(.caption).foregroundStyle(.orange)
        }
        if section == "patches", review.nextPatchID != nil {
          Button("Earlier patches", action: earlier)
        }
        Picker("Changes", selection: $section) {
          Text("Unstaged now").tag("unstaged")
          Text("Staged now").tag("staged")
          Text("Starting changes").tag("baseline")
          Text("Hex patches").tag("patches")
        }.pickerStyle(.segmented)
        ScrollView([.vertical, .horizontal]) {
          VStack(alignment: .leading, spacing: 12) {
            if section == "patches" {
              if review.patches.isEmpty {
                Text("No typed Hex patches have been recorded for this request.")
              }
              ForEach(review.patches, id: \.id) { patch in
                Text(patch.state.capitalized).font(.headline)
                ForEach(patch.files.indices, id: \.self) { index in
                  Button("\(patch.files[index].state)  \(patch.files[index].path)") {
                    openPatch(patch.id, index)
                  }
                  .buttonStyle(.link)
                  if let tombstone = patch.files[index].tombstone {
                    Text("Recovery copy: \(tombstone)").foregroundStyle(.secondary)
                  }
                }
                if !patch.explanation.isEmpty { Text(patch.explanation).foregroundStyle(.orange) }
                Divider()
              }
            } else if section == "baseline" {
              if let baseline = review.baseline {
                Text(
                  "Staged at start\n" + baseline.stagedDiff + "\nUnstaged at start\n"
                    + baseline.unstagedDiff)
                ForEach(baseline.untracked.keys.sorted(), id: \.self) {
                  Text("Already untracked: " + $0)
                }
              } else {
                Text("No coding baseline has been captured for this request yet.")
              }
            } else if let current = review.current, !current.repository.isEmpty {
              let diff = section == "staged" ? current.stagedDiff : current.unstagedDiff
              Text(diff.isEmpty ? "No \(section) diff." : diff)
              if section == "unstaged" {
                ForEach(current.untracked.keys.sorted(), id: \.self) { Text("Untracked: " + $0) }
              }
            } else {
              Text(
                "The configured workspace is not a Git repository root. Typed patch receipts are available under Hex patches."
              )
            }
          }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        }.defaultScrollAnchor(.topLeading, for: .alignment)
          .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
      } else {
        ContentUnavailableView(
          "Changes", systemImage: "doc.text.magnifyingglass",
          description: Text("Refresh to inspect changes for this request."))
      }
    }
  }
}
