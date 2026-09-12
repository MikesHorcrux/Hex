import Foundation

public struct WorkspaceChangesReview: Codable, Sendable {
  public let taskID: UUID
  public let baseline: GitWorkspaceSnapshot?
  public let current: GitWorkspaceSnapshot?
  public let patches: [WorkspacePatchReceipt]
  public let explanation: String
  public let nextPatchID: String?
  public let totalPatchCount: Int
  public init(
    taskID: UUID, baseline: GitWorkspaceSnapshot?, current: GitWorkspaceSnapshot?,
    patches: [WorkspacePatchReceipt], explanation: String, nextPatchID: String? = nil,
    totalPatchCount: Int? = nil
  ) {
    self.taskID = taskID
    self.baseline = baseline
    self.current = current
    self.patches = patches
    self.explanation = explanation
    self.nextPatchID = nextPatchID
    self.totalPatchCount = totalPatchCount ?? patches.count
  }
}
