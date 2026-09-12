import Foundation
import HexCore

extension CodingWorkspaceManager {
  public func reconcile(taskID: UUID, operationID: UUID) async throws {
    try await acquire()
    defer { busy = false }
    for var receipt in try await store().codingPatches(taskID)
    where receipt.state != "completed" && receipt.state != "reconciled" {
      for index in receipt.files.indices {
        let file = receipt.files[index]
        do {
          let current = try await fileSystem.readTextFile(at: file.path, relativeTo: workspace)
          if current.revision == file.after?.sha256 {
            receipt.files[index].state = "observed_after"
          } else if current.revision == file.before?.sha256 {
            receipt.files[index].state = "observed_before"
          } else {
            receipt.files[index].state = "conflicted"
          }
        } catch WorkspaceFileSystemError.notFound {
          receipt.files[index].state =
            file.after == nil
            ? "observed_after" : (file.before == nil ? "observed_before" : "conflicted")
        } catch { receipt.files[index].state = "unknown" }
      }
      receipt.state = "reconciled"
      receipt.reconciliationID = operationID
      receipt.explanation =
        "Current file revisions were observed after the user's reconciliation decision. No patch was replayed or rolled back; observations do not prove who changed a file."
      try await store().saveCodingPatch(receipt)
    }
  }
}
