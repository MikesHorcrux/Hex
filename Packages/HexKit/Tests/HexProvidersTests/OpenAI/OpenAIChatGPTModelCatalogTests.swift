import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("ChatGPT model catalog")
struct OpenAIChatGPTModelCatalogTests {
  @Test
  func authenticatedDiscoveryKeepsOnlyPickerMetadataAndCachesIt() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [
      OpenAIResponsesTestFixture.response(
        data: Data(
          #"""
          {"models":[
            {"slug":"gpt-visible","display_name":"Visible model","visibility":"list",
             "priority":1,"context_window":200000,"input_modalities":["text","image"],
             "supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"},{"effort":"future"}],
             "default_reasoning_level":"low","base_instructions":"Do not copy these"},
            {"slug":"gpt-hidden","display_name":"Hidden","visibility":"hide"}
          ]}
          """#.utf8), contentType: "application/json")
    ])
    let catalog = OpenAIChatGPTModelCatalog(
      authorizationProvider: Authorization(), transport: transport)
    let models = try await catalog.availableModels()
    #expect(models.count == 1)
    #expect(models.first?.id.rawValue == "gpt-visible")
    #expect(models.first?.displayName == "Visible model")
    #expect(models.first?.supportedReasoningEfforts == [.low, .ultra])
    #expect(models.first?.defaultReasoningEffort == .low)
    #expect(models.first?.capabilities.contains(.imageInput) == true)
    #expect(try await catalog.availableModels() == models)
    let requests = await transport.requests()
    let request = try #require(requests.first)
    #expect(requests.count == 1)
    #expect(request.url?.host == "chatgpt.com")
    #expect(request.url?.path == "/backend-api/codex/models")
    #expect(request.url?.query == "client_version=0.144.0")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Hex/1.0")
    #expect(request.value(forHTTPHeaderField: "originator") == "hex")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
  }

  @Test
  func emptySuccessfulCatalogDoesNotInventModelChoices() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [
      OpenAIResponsesTestFixture.response(
        data: Data(#"{"models":[]}"#.utf8),
        contentType: "application/json")
    ])
    let catalog = OpenAIChatGPTModelCatalog(
      authorizationProvider: Authorization(), transport: transport)
    await #expect(throws: OpenAIResponsesProviderError.unsupportedModel) {
      try await catalog.availableModels()
    }
  }

  @Test
  func duplicateCatalogIdentifiersAreRejected() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [
      OpenAIResponsesTestFixture.response(
        data: Data(
          #"""
          {"models":[
            {"slug":"duplicate","display_name":"First","visibility":"list"},
            {"slug":"duplicate","display_name":"Second","visibility":"list"}
          ]}
          """#.utf8), contentType: "application/json")
    ])
    let catalog = OpenAIChatGPTModelCatalog(
      authorizationProvider: Authorization(), transport: transport)
    await #expect(throws: OpenAIResponsesProviderError.invalidConfiguration) {
      try await catalog.availableModels()
    }
  }

  @Test
  func discoveryFailureKeepsConfiguredModelAndDoesNotRetryEveryTurn() async throws {
    let catalog = FailingCatalog()
    let model = OpenAIResponsesTestFixture.model()
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(models: [model]),
      authorizationProvider: Authorization(), modelCatalog: catalog
    )
    #expect(try await provider.availableModels() == [model])
    #expect(try await provider.availableModels() == [model])
    #expect(await catalog.calls == 1)
  }

  private struct Authorization: OpenAIResponsesAuthorizationProvider {
    func authorization() async throws -> OpenAIResponsesAuthorization {
      OpenAIResponsesAuthorization(bearerToken: "test-token", accountID: "test-account")
    }
  }

  private actor FailingCatalog: OpenAIModelCatalogLoading {
    var calls = 0
    func availableModels() async throws -> [ModelDescriptor] {
      calls += 1
      throw URLError(.timedOut)
    }
  }
}
