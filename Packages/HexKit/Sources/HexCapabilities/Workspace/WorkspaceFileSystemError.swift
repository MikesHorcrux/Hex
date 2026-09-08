public enum WorkspaceFileSystemError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidRoot
  case invalidPath
  case invalidWorkingDirectory
  case notFound
  case notDirectory
  case notRegularFile
  case symbolicLinkRejected
  case hardLinkRejected
  case fileTooLarge
  case invalidUTF8
  case capacityExceeded
  case destinationExists
  case invalidRevision
  case revisionConflict
  case replacementCountMismatch
  case ioFailure
  case accessDenied
  case outcomeUncertain
}
