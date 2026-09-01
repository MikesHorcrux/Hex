import HexCore
import Testing

@testable import HexProviders

@Suite("Codex Bedrock account compatibility")
struct CodexAccountBedrockCompatibilityTests {
  @Test
  func readsLegacyDefaultWhenManagedCredentialFlagIsOmitted() async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(accountResponse(["type": .string("amazonBedrock")]))
      ]
    )
    let client = CodexAccountClient(transport: transport)

    #expect(
      try await client.readAccount()
        == CodexAccountSnapshot(
          account: .amazonBedrock(usesCodexManagedCredentials: false),
          requiresOpenAIAuthentication: false
        )
    )
  }

  @Test(arguments: [true, false])
  func readsLegacyManagedCredentialFlag(
    usesCodexManagedCredentials: Bool
  ) async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          accountResponse([
            "type": .string("amazonBedrock"),
            "usesCodexManagedCredentials": .boolean(usesCodexManagedCredentials),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)

    #expect(
      try await client.readAccount()
        == CodexAccountSnapshot(
          account: .amazonBedrock(
            usesCodexManagedCredentials: usesCodexManagedCredentials
          ),
          requiresOpenAIAuthentication: false
        )
    )
  }

  @Test(arguments: [
    ("codexManaged", true),
    ("awsManaged", false),
  ])
  func readsDocumentedCredentialSource(
    credentialSource: String,
    expectedCodexManaged: Bool
  ) async throws {
    let transport = TestCodexAppServerTransport(
      outcomes: [
        .value(
          accountResponse([
            "type": .string("amazonBedrock"),
            "credentialSource": .string(credentialSource),
          ])
        )
      ]
    )
    let client = CodexAccountClient(transport: transport)

    #expect(
      try await client.readAccount()
        == CodexAccountSnapshot(
          account: .amazonBedrock(
            usesCodexManagedCredentials: expectedCodexManaged
          ),
          requiresOpenAIAuthentication: false
        )
    )
  }

  @Test(arguments: [
    [
      "type": JSONValue.string("amazonBedrock"),
      "usesCodexManagedCredentials": .boolean(true),
      "credentialSource": .string("codexManaged"),
    ],
    [
      "type": .string("amazonBedrock"),
      "credentialSource": .string("futureManaged"),
    ],
    [
      "type": .string("amazonBedrock"),
      "credentialSource": .boolean(true),
    ],
    [
      "type": .string("amazonBedrock"),
      "credentialSource": .string("awsManaged"),
      "futureCredential": .string("secret"),
    ],
  ])
  func rejectsMixedUnknownAndMalformedCredentialShapes(
    account: [String: JSONValue]
  ) async throws {
    let client = CodexAccountClient(
      transport: TestCodexAppServerTransport(
        outcomes: [.value(accountResponse(account))]
      )
    )

    await #expect(throws: CodexAccountClientError.malformedResponse) {
      try await client.readAccount()
    }
  }

  private func accountResponse(_ account: [String: JSONValue]) -> JSONValue {
    .object([
      "account": .object(account),
      "requiresOpenaiAuth": .boolean(false),
    ])
  }
}
