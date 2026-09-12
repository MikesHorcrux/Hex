import HexCore
import SwiftUI

struct AgentPatchPreviewView: View {
  let preview: WorkspaceFileChangePreview
  @State private var after = true
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(preview.path).font(.headline)
        Spacer()
        Button("Done") { dismiss() }.buttonStyle(.hexSecondaryAction)
      }
      HexSegmentedPicker(
        title: "Saved image", options: [false, true], selection: $after,
        label: { $0 ? "Proposed after" : "Before" })
      Text(
        "These saved images describe the patch. Its receipt records whether each file was applied."
      ).font(.caption).foregroundStyle(.secondary)
      if preview.truncated {
        Text("Preview limited to 32 KiB per image; the full recovery images remain saved.").font(
          .caption)
      }
      HexCodeScrollView {
        Text((after ? preview.after : preview.before) ?? "File absent")
      }
    }.padding(20).frame(minWidth: 700, minHeight: 500)
  }
}
