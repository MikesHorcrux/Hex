enum ArtifactToolError: Error, Equatable, Sendable {
  case unknownArtifact
  case invalidReference
  case inconsistentChunk
  case insufficientSearchWindow
}
