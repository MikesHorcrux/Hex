public struct WorkspaceFileSystemConfiguration: Equatable, Sendable {
  public static let standard = WorkspaceFileSystemConfiguration(
    validatedMaximumReadBytes: 512 * 1_024,
    maximumWriteBytes: 1 * 1_024 * 1_024,
    maximumDirectoryEntries: 4_096,
    maximumDirectoryResultBytes: 512 * 1_024,
    maximumSearchFiles: 10_000,
    maximumSearchBytes: 32 * 1_024 * 1_024,
    maximumSearchMatches: 500,
    maximumSearchDepth: 64,
    excludedSearchDirectoryNames: [".build", ".git", ".swiftpm", "DerivedData"]
  )

  public let maximumReadBytes: Int
  public let maximumWriteBytes: Int
  public let maximumDirectoryEntries: Int
  public let maximumDirectoryResultBytes: Int
  public let maximumSearchFiles: Int
  public let maximumSearchBytes: Int
  public let maximumSearchMatches: Int
  public let maximumSearchDepth: Int
  public let excludedSearchDirectoryNames: Set<String>

  public init(
    maximumReadBytes: Int = 512 * 1_024,
    maximumWriteBytes: Int = 1 * 1_024 * 1_024,
    maximumDirectoryEntries: Int = 4_096,
    maximumDirectoryResultBytes: Int = 512 * 1_024,
    maximumSearchFiles: Int = 10_000,
    maximumSearchBytes: Int = 32 * 1_024 * 1_024,
    maximumSearchMatches: Int = 500,
    maximumSearchDepth: Int = 64,
    excludedSearchDirectoryNames: Set<String> = [".build", ".git", ".swiftpm", "DerivedData"]
  ) throws {
    guard
      (1...16 * 1_024 * 1_024).contains(maximumReadBytes),
      (1...16 * 1_024 * 1_024).contains(maximumWriteBytes),
      (1...100_000).contains(maximumDirectoryEntries),
      (1...16 * 1_024 * 1_024).contains(maximumDirectoryResultBytes),
      (1...1_000_000).contains(maximumSearchFiles),
      (1...1 * 1_024 * 1_024 * 1_024).contains(maximumSearchBytes),
      (1...100_000).contains(maximumSearchMatches),
      (1...256).contains(maximumSearchDepth),
      excludedSearchDirectoryNames.count <= 256,
      excludedSearchDirectoryNames.allSatisfy(Self.isValidDirectoryName)
    else {
      throw WorkspaceFileSystemError.invalidConfiguration
    }
    self.init(
      validatedMaximumReadBytes: maximumReadBytes,
      maximumWriteBytes: maximumWriteBytes,
      maximumDirectoryEntries: maximumDirectoryEntries,
      maximumDirectoryResultBytes: maximumDirectoryResultBytes,
      maximumSearchFiles: maximumSearchFiles,
      maximumSearchBytes: maximumSearchBytes,
      maximumSearchMatches: maximumSearchMatches,
      maximumSearchDepth: maximumSearchDepth,
      excludedSearchDirectoryNames: excludedSearchDirectoryNames
    )
  }

  private init(
    validatedMaximumReadBytes maximumReadBytes: Int,
    maximumWriteBytes: Int,
    maximumDirectoryEntries: Int,
    maximumDirectoryResultBytes: Int,
    maximumSearchFiles: Int,
    maximumSearchBytes: Int,
    maximumSearchMatches: Int,
    maximumSearchDepth: Int,
    excludedSearchDirectoryNames: Set<String>
  ) {
    self.maximumReadBytes = maximumReadBytes
    self.maximumWriteBytes = maximumWriteBytes
    self.maximumDirectoryEntries = maximumDirectoryEntries
    self.maximumDirectoryResultBytes = maximumDirectoryResultBytes
    self.maximumSearchFiles = maximumSearchFiles
    self.maximumSearchBytes = maximumSearchBytes
    self.maximumSearchMatches = maximumSearchMatches
    self.maximumSearchDepth = maximumSearchDepth
    self.excludedSearchDirectoryNames = excludedSearchDirectoryNames
  }

  private static func isValidDirectoryName(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && value.utf8.count <= 255
      && !value.contains("/")
      && !value.contains("\0")
  }
}
