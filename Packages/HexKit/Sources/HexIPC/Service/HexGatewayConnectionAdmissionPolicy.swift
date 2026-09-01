import Darwin

/// Admission policy for the resident gateway's local Mach-service clients.
///
/// The listener installs `codeSigningRequirement` before activation, which makes the operating
/// system reject a peer that does not satisfy the requirement before the delegate is consulted. The
/// delegate then applies `expectedEffectiveUserIdentifier` as a second, same-user boundary. The
/// production policy intentionally rejects unsigned app bundles. The supported resident Debug path
/// signs and verifies its staged bundle against this exact requirement instead of weakening it.
public struct HexGatewayConnectionAdmissionPolicy: Equatable, Sendable {
  public static let productionApplicationBundleIdentifier = "com.lunarmothstudios.Hex"
  public static let productionApplicationTeamIdentifier = "5V5PZUN2HG"
  public static let productionCodeSigningRequirement =
    #"anchor apple generic and identifier "com.lunarmothstudios.Hex" and certificate leaf[subject.OU] = "5V5PZUN2HG""#

  public let codeSigningRequirement: String
  public let expectedEffectiveUserIdentifier: UInt32

  public init(
    codeSigningRequirement: String,
    expectedEffectiveUserIdentifier: UInt32
  ) {
    self.codeSigningRequirement = codeSigningRequirement
    self.expectedEffectiveUserIdentifier = expectedEffectiveUserIdentifier
  }

  public static func production(
    expectedEffectiveUserIdentifier: UInt32 = UInt32(geteuid())
  ) -> Self {
    Self(
      codeSigningRequirement: productionCodeSigningRequirement,
      expectedEffectiveUserIdentifier: expectedEffectiveUserIdentifier
    )
  }

  /// Returns whether the peer's effective user matches the resident process user.
  /// Code-signing admission is enforced by `NSXPCListener` before this method is reached.
  public func accepts(effectiveUserIdentifier: UInt32) -> Bool {
    effectiveUserIdentifier == expectedEffectiveUserIdentifier
  }
}
