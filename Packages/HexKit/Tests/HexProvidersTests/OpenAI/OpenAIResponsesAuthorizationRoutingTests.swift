import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses authorization routing")
struct OpenAIResponsesAuthorizationRoutingTests {
  @Test
  func apiKeyUsesPlatformEndpointWithoutSubscriptionHeaders() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream()
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: responseData)]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .platformAPI,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(bearerToken: "platform-api-key")
      ),
      transport: transport
    )

    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    let sent = try #require(await transport.requests().first)
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer platform-api-key")
    #expect(sent.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil)
    #expect(sent.value(forHTTPHeaderField: "originator") == nil)
    let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
    #expect(body["store"] as? Bool == true)
  }

  @Test
  func chatGPTSubscriptionUsesCodexEndpointAndHeadersWithoutServerStorage() async throws {
    let responseData = try OpenAIResponsesTestFixture.textStream()
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: responseData)]
    )
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    _ = try await OpenAIResponsesTestFixture.collect(
      provider: provider,
      request: OpenAIResponsesTestFixture.request()
    )

    let sent = try #require(await transport.requests().first)
    #expect(sent.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer subscription-access-token")
    #expect(sent.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-test")
    #expect(sent.value(forHTTPHeaderField: "originator") == "hex")
    #expect(sent.value(forHTTPHeaderField: "User-Agent") == "Hex/1.0")

    let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
    #expect(body["store"] as? Bool == false)
    #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
    #expect(body["previous_response_id"] == nil)
  }

  @Test
  func platformAPIRejectsSubscriptionAuthorizationBeforeNetworkUse() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let configuration = try OpenAIResponsesConfiguration(
      service: .platformAPI,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(
          bearerToken: "subscription-access-token",
          accountID: "account-test"
        )
      ),
      transport: transport
    )

    do {
      _ = try await provider.stream(OpenAIResponsesTestFixture.request())
      Issue.record("Expected subscription authorization to be rejected on the API-key route.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .credentialUnavailable)
    }

    #expect(await transport.requests().isEmpty)
  }

  @Test
  func chatGPTSubscriptionRequiresAnAccountIDBeforeNetworkUse() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let configuration = try OpenAIResponsesConfiguration(
      service: .chatGPTCodexSubscription,
      models: [OpenAIResponsesTestFixture.model()]
    )
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      authorizationProvider: StaticAuthorizationProvider(
        value: OpenAIResponsesAuthorization(bearerToken: "subscription-access-token")
      ),
      transport: transport
    )

    do {
      _ = try await provider.stream(OpenAIResponsesTestFixture.request())
      Issue.record("Expected ChatGPT authorization without an account ID to be rejected.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .credentialUnavailable)
    }

    #expect(await transport.requests().isEmpty)
  }

  private struct StaticAuthorizationProvider: OpenAIResponsesAuthorizationProvider {
    let value: OpenAIResponsesAuthorization

    func authorization() async throws -> OpenAIResponsesAuthorization {
      value
    }
  }
}
