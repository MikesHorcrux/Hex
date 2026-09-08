import Foundation

struct MLXModelArtifactSnapshotClaim: Sendable {
  let url: URL
  let fileDescriptor: Int32
  let identity: MLXModelArtifactSnapshotIdentity
}
