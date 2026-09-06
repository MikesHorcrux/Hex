public struct WorkspaceSearchReport: Equatable, Sendable {
  public let matches: [WorkspaceSearchMatch]
  public let skippedOversizedFiles: Int

  public init(matches: [WorkspaceSearchMatch], skippedOversizedFiles: Int) {
    self.matches = matches
    self.skippedOversizedFiles = skippedOversizedFiles
  }
}
