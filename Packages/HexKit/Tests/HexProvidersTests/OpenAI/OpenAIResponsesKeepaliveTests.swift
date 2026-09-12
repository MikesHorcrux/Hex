import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI subscription keepalive")
struct OpenAIResponsesKeepaliveTests {
  private struct StaticAuthorizationProvider: OpenAIResponsesAuthorizationProvider {
    let value: OpenAIResponsesAuthorization
    func authorization() async throws -> OpenAIResponsesAuthorization { value }
  }

  @Test func heartbeatDuringGenerationPreservesTheCompletedResponse() async throws {
    let ordinary = try OpenAIResponsesTestFixture.textStream(text: "site ready")
    let boundary = try #require(ordinary.range(of: Data("\n\n".utf8)))
    var bytes = Data(ordinary[..<boundary.upperBound])
    try OpenAIResponsesTestFixture.appendEvent(
      ["type": "keepalive"], to: &bytes, eventName: "keepalive")
    bytes.append(ordinary[boundary.upperBound...])
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesConfiguration(
        service: .chatGPTCodexSubscription, models: [OpenAIResponsesTestFixture.model()]),
      authorizationProvider: StaticAuthorizationProvider(
        value: .init(bearerToken: "test-token", accountID: "test-account")),
      transport: TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: bytes)]))
    let events = try await OpenAIResponsesTestFixture.collect(
      provider: provider, request: OpenAIResponsesTestFixture.request())
    #expect(events.contains(.textDelta("site ready")))
  }

  @Test func heartbeatAloneNeverCompletesAResponse() throws {
    var processor = try processor(service: .chatGPTCodexSubscription)
    let result = try processor.process(event(["type": "keepalive"]))
    #expect(result.events.isEmpty)
    #expect(result.terminalResult == nil)
    #expect(throws: OpenAIResponsesProviderError.truncatedStream) { try processor.finish() }
  }

  @Test func malformedSequenceAndUnknownEventsStillFailClosed() throws {
    var processor = try processor(service: .chatGPTCodexSubscription)
    let badSequence = try event(["type": "keepalive", "sequence_number": -1])
    #expect(throws: OpenAIResponsesProviderError.malformedStream) {
      try processor.process(badSequence)
    }
    let unknown = try event(["type": "unknown-event"])
    #expect(throws: OpenAIResponsesProviderError.malformedStream) {
      try processor.process(unknown)
    }
  }

  @Test func platformRouteDoesNotAcquireSubscriptionExceptions() throws {
    var processor = try processor(service: .platformAPI)
    let heartbeat = try event(["type": "keepalive"])
    #expect(throws: OpenAIResponsesProviderError.malformedStream) {
      try processor.process(heartbeat)
    }
  }

  private func processor(service: OpenAIResponsesService) throws -> OpenAIResponsesStreamProcessor {
    OpenAIResponsesStreamProcessor(
      configuration: try OpenAIResponsesConfiguration(
        service: service, models: [OpenAIResponsesTestFixture.model()]),
      tools: [], toolChoice: .automatic, allowsParallelToolCalls: false)
  }

  private func event(_ object: [String: Any]) throws -> ServerSentEvent {
    ServerSentEvent(
      name: object["type"] as? String,
      data: try JSONSerialization.data(withJSONObject: object))
  }
}
