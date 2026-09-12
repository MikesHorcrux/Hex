public struct CapabilityAuthorizationCenterConfiguration: Equatable, Sendable {
  public static let standard = CapabilityAuthorizationCenterConfiguration(
    validatedMaximumCapabilityBytes: 256,
    validatedMaximumOperationBytes: 256,
    validatedMaximumResourceBytes: 16_384,
    validatedMaximumExplanationBytes: 16_384,
    validatedMaximumDetailsBytes: 65_536,
    validatedMaximumRunGrants: 2_048,
    validatedMaximumSessionGrants: 1_024
  )

  public let maximumCapabilityBytes: Int
  public let maximumOperationBytes: Int
  public let maximumResourceBytes: Int
  public let maximumExplanationBytes: Int
  public let maximumDetailsBytes: Int
  public let maximumRunGrants: Int
  public let maximumSessionGrants: Int

  public init?(
    maximumCapabilityBytes: Int,
    maximumOperationBytes: Int,
    maximumResourceBytes: Int,
    maximumExplanationBytes: Int,
    maximumDetailsBytes: Int,
    maximumRunGrants: Int,
    maximumSessionGrants: Int
  ) {
    let textHardMaximum = 1_048_576
    let detailsHardMaximum = 4_194_304
    let grantsHardMaximum = 65_536
    guard
      (1...textHardMaximum).contains(maximumCapabilityBytes),
      (1...textHardMaximum).contains(maximumOperationBytes),
      (1...textHardMaximum).contains(maximumResourceBytes),
      (1...textHardMaximum).contains(maximumExplanationBytes),
      (1...detailsHardMaximum).contains(maximumDetailsBytes),
      (1...grantsHardMaximum).contains(maximumRunGrants),
      (1...grantsHardMaximum).contains(maximumSessionGrants)
    else {
      return nil
    }

    self.init(
      validatedMaximumCapabilityBytes: maximumCapabilityBytes,
      validatedMaximumOperationBytes: maximumOperationBytes,
      validatedMaximumResourceBytes: maximumResourceBytes,
      validatedMaximumExplanationBytes: maximumExplanationBytes,
      validatedMaximumDetailsBytes: maximumDetailsBytes,
      validatedMaximumRunGrants: maximumRunGrants,
      validatedMaximumSessionGrants: maximumSessionGrants
    )
  }

  private init(
    validatedMaximumCapabilityBytes maximumCapabilityBytes: Int,
    validatedMaximumOperationBytes maximumOperationBytes: Int,
    validatedMaximumResourceBytes maximumResourceBytes: Int,
    validatedMaximumExplanationBytes maximumExplanationBytes: Int,
    validatedMaximumDetailsBytes maximumDetailsBytes: Int,
    validatedMaximumRunGrants maximumRunGrants: Int,
    validatedMaximumSessionGrants maximumSessionGrants: Int
  ) {
    self.maximumCapabilityBytes = maximumCapabilityBytes
    self.maximumOperationBytes = maximumOperationBytes
    self.maximumResourceBytes = maximumResourceBytes
    self.maximumExplanationBytes = maximumExplanationBytes
    self.maximumDetailsBytes = maximumDetailsBytes
    self.maximumRunGrants = maximumRunGrants
    self.maximumSessionGrants = maximumSessionGrants
  }
}
