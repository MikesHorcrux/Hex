struct WorkspaceRelativePath: Equatable, Sendable {
  let components: [String]

  init(_ rawValue: String) throws {
    guard
      !rawValue.isEmpty,
      rawValue.utf8.count <= 4_096,
      !rawValue.contains("\0"),
      !rawValue.hasPrefix("/")
    else {
      throw WorkspaceFileSystemError.invalidPath
    }
    if rawValue == "." {
      components = []
      return
    }
    let candidates = rawValue.split(separator: "/", omittingEmptySubsequences: false)
    guard
      candidates.count <= 256,
      candidates.allSatisfy({ component in
        !component.isEmpty
          && component != "."
          && component != ".."
          && component.utf8.count <= 255
      })
    else {
      throw WorkspaceFileSystemError.invalidPath
    }
    components = candidates.map(String.init)
  }
}
