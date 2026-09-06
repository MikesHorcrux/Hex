import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI service output-limit capabilities")
struct OpenAIResponsesOutputLimitTests {
  @Test
  func reportsTheActualServiceOutputLimitCapability() throws {
    for service in [OpenAIResponsesService.platformAPI, .chatGPTCodexSubscription] {
      let provider = OpenAIResponsesProvider(
        configuration: try configuration(service),
        credentialProvider: TestOpenAICredentialProvider(key: "unused-test-value"))
      let reporting: any InferenceOutputLimitReporting = provider
      #expect(reporting.supportsServerOutputTokenLimit == (service == .platformAPI))
    }
  }

  @Test
  func rejectsAnExplicitSubscriptionOutputLimitBeforeTransport() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let provider = OpenAIResponsesProvider(
      configuration: try configuration(.chatGPTCodexSubscription),
      credentialProvider: TestOpenAICredentialProvider(key: "unused-test-value"),
      transport: transport)
    await #expect(throws: OpenAIResponsesProviderError.unsupportedOutputTokenLimit) {
      try await provider.stream(
        OpenAIResponsesTestFixture.request(
          options: InferenceOptions(maxOutputTokens: 128)))
    }
    #expect(await transport.requests().isEmpty)
    let failure = OpenAIResponsesProviderError.unsupportedOutputTokenLimit
    #expect(!failure.isRetryable)
    #expect(failure.userFacingMessage.contains("ChatGPT"))
    #expect(failure.userFacingMessage.contains("remove"))
  }

  @Test
  func preservesAPIOutputLimitMappingAndLeavesUncappedSubscriptionRequestsUntouched() throws {
    let api = try OpenAIResponsesRequestBuilder(configuration: configuration(.platformAPI)).build(
      OpenAIResponsesTestFixture.request(options: InferenceOptions(maxOutputTokens: 128)),
      serverState: nil, localState: nil)
    let apiBody = try #require(JSONSerialization.jsonObject(with: api.body) as? [String: Any])
    #expect(apiBody["max_output_tokens"] as? Int == 128)
    let subscription = try OpenAIResponsesRequestBuilder(
      configuration: configuration(.chatGPTCodexSubscription)
    ).build(OpenAIResponsesTestFixture.request(), serverState: nil, localState: nil)
    let subscriptionBody = try #require(
      JSONSerialization.jsonObject(with: subscription.body) as? [String: Any])
    #expect(subscriptionBody["max_output_tokens"] == nil)
  }

  private func configuration(_ service: OpenAIResponsesService) throws
    -> OpenAIResponsesConfiguration
  {
    try OpenAIResponsesConfiguration(service: service, models: [OpenAIResponsesTestFixture.model()])
  }
}
