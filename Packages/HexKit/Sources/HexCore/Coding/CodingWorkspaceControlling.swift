import Foundation

public protocol CodingWorkspaceControlling: Sendable {
  func patchFile(taskID: UUID, receiptID: String, index: Int) async throws
    -> WorkspaceFileChangePreview
  func reconcile(taskID: UUID, operationID: UUID) async throws
  func review(taskID: UUID, before: String?, limit: Int) async throws -> WorkspaceChangesReview
}
