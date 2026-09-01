struct MLXModelArtifactSnapshotEntry: Sendable {
  let name: String
  let fileDescriptor: Int32
  let identity: MLXModelArtifactSnapshotIdentity
}
