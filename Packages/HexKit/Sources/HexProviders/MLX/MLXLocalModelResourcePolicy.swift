public struct MLXLocalModelResourcePolicy: Equatable, Sendable {
  public static var macWith16GBMemory: MLXLocalModelResourcePolicy {
    get throws {
      try MLXLocalModelResourcePolicy(
        maximumArtifactBytes: 6 * 1_024 * 1_024 * 1_024,
        maximumControlFileBytes: 64 * 1_024 * 1_024,
        maximumArtifactCount: 512,
        maximumContextTokens: 32_768,
        maximumOutputTokens: 8_192
      )
    }
  }

  public let maximumArtifactBytes: UInt64
  public let maximumControlFileBytes: UInt64
  public let maximumArtifactCount: Int
  public let maximumContextTokens: Int
  public let maximumOutputTokens: Int

  public init(
    maximumArtifactBytes: UInt64,
    maximumControlFileBytes: UInt64,
    maximumArtifactCount: Int
  ) throws {
    try self.init(
      maximumArtifactBytes: maximumArtifactBytes,
      maximumControlFileBytes: maximumControlFileBytes,
      maximumArtifactCount: maximumArtifactCount,
      maximumContextTokens: 32_768,
      maximumOutputTokens: 8_192
    )
  }

  public init(
    maximumArtifactBytes: UInt64,
    maximumControlFileBytes: UInt64,
    maximumArtifactCount: Int,
    maximumContextTokens: Int,
    maximumOutputTokens: Int
  ) throws {
    guard
      (1...(64 * 1_024 * 1_024 * 1_024)).contains(maximumArtifactBytes),
      (1...maximumArtifactBytes).contains(maximumControlFileBytes),
      (3...4_096).contains(maximumArtifactCount),
      (1...1_000_000).contains(maximumContextTokens),
      (1...maximumContextTokens).contains(maximumOutputTokens)
    else {
      throw MLXLocalInferenceProviderError.invalidModelConfiguration
    }
    self.maximumArtifactBytes = maximumArtifactBytes
    self.maximumControlFileBytes = maximumControlFileBytes
    self.maximumArtifactCount = maximumArtifactCount
    self.maximumContextTokens = maximumContextTokens
    self.maximumOutputTokens = maximumOutputTokens
  }
}
