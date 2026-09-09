import Foundation
import HexCore

extension CodingWorkspaceManager {
  public func patchFile(taskID: UUID, receiptID: String, index: Int) async throws
    -> WorkspaceFileChangePreview
  {
    guard let receipt = try await store().codingPatch(receiptID), receipt.scope.taskID == taskID,
      receipt.files.indices.contains(index), let reader = artifacts as? any ArtifactReading
    else { throw WorkspacePatchError.unavailable }
    let file = receipt.files[index]
    var before: String?
    var after: String?
    if let reference = file.before {
      before = String(
        decoding: try await reader.read(reference, offset: 0, maximumBytes: 32_768).data,
        as: UTF8.self)
    }
    if let reference = file.after {
      after = String(
        decoding: try await reader.read(reference, offset: 0, maximumBytes: 32_768).data,
        as: UTF8.self)
    }
    return WorkspaceFileChangePreview(
      id: "\(receiptID):\(index)", path: file.path, before: before, after: after,
      truncated: (file.before?.byteCount ?? 0) > 32_768 || (file.after?.byteCount ?? 0) > 32_768)
  }
}
