import Foundation

public protocol CodingWorkspaceStorage: Sendable {
  func codingBaseline(_ taskID: UUID) async throws -> GitWorkspaceSnapshot?
  func saveCodingBaseline(_ snapshot: GitWorkspaceSnapshot, taskID: UUID) async throws
  func codingPatch(_ id: String) async throws -> WorkspacePatchReceipt?
  func saveCodingPatch(_ receipt: WorkspacePatchReceipt) async throws
  func codingPatches(_ taskID: UUID) async throws -> [WorkspacePatchReceipt]
  func codingGeneration(_ taskID: UUID) async throws -> Int64
}
