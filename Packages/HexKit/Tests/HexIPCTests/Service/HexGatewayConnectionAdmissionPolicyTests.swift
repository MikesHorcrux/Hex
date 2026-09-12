import HexCore
import HexIPC
import Testing

@Suite("Gateway connection admission")
struct HexGatewayConnectionAdmissionPolicyTests {
  @Test
  func productionRequirementNamesHexAndRejectsBroadRequirements() {
    let policy = HexGatewayConnectionAdmissionPolicy.production(
      expectedEffectiveUserIdentifier: 501
    )

    #expect(
      policy.codeSigningRequirement
        == HexGatewayConnectionAdmissionPolicy.productionCodeSigningRequirement
    )
    if HexSigningIdentity.current != nil {
      #expect(policy.codeSigningRequirement.contains("com.lunarmothstudios.Hex"))
      #expect(
        policy.codeSigningRequirement.contains(
          HexGatewayConnectionAdmissionPolicy.productionApplicationTeamIdentifier
        ))
    } else {
      #expect(policy.codeSigningRequirement == "never")
    }
    #expect(!policy.codeSigningRequirement.contains("true"))
  }

  @Test
  func injectedPolicyRejectsPeersFromAnotherEffectiveUser() {
    let policy = HexGatewayConnectionAdmissionPolicy(
      codeSigningRequirement: #"identifier "com.example.HexTest""#,
      expectedEffectiveUserIdentifier: 501
    )

    #expect(policy.accepts(effectiveUserIdentifier: 501))
    #expect(!policy.accepts(effectiveUserIdentifier: 502))
  }
}
