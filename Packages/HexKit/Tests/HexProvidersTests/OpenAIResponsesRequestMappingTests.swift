import Foundation
import HexCore
import Testing

@testable import HexProviders

@Suite("OpenAI Responses request mapping")
struct OpenAIResponsesRequestMappingTests {
  @Test
  func mapsEveryNeutralInputAndBothPrivacyModes() async throws {
    let imageURL = try #require(URL(string: "https://images.example.test/cat.png"))
    let call = ToolCall(
      id: ToolCallID(rawValue: "call_history"),
      name: "lookup_weather",
      arguments: ["city": .string("Paris")]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .failure,
      output: .object(["message": .string("offline")])
    )
    let messages = [
      Message(role: .system, content: [.text("Keep responses concise.")]),
      Message(
        role: .user,
        content: [
          .text("What is in this image?"),
          .image(ImageContent(sourceURL: imageURL, mediaType: "image/png")),
        ]
      ),
      Message(role: .assistant, content: [.text("I will check."), .toolCall(call)]),
      Message(role: .tool, content: [.toolResult(result)]),
    ]
    let tools = [
      ToolDefinition(
        name: "lookup_weather",
        description: "Look up weather for a city.",
        inputSchema: [
          "type": .string("object"),
          "properties": .object(["city": .object(["type": .string("string")])]),
          "required": .array([.string("city")]),
          "additionalProperties": .boolean(false),
        ]
      )
    ]

    for mode in OpenAIResponsesPrivacyMode.allCases {
      let responseData = try OpenAIResponsesTestFixture.textStream(responseID: "resp_mapping")
      let transport = TestOpenAIResponsesTransport(
        responses: [OpenAIResponsesTestFixture.response(data: responseData)]
      )
      let configuration = try OpenAIResponsesTestFixture.configuration(privacyMode: mode)
      let provider = OpenAIResponsesProvider(
        configuration: configuration,
        credentialProvider: TestOpenAICredentialProvider(key: "sk-platform-test"),
        transport: transport
      )
      let request = OpenAIResponsesTestFixture.request(
        messages: messages,
        tools: tools,
        toolChoice: .named("lookup_weather"),
        options: InferenceOptions(maxOutputTokens: 128, temperature: 0.5)
      )

      let events = try await OpenAIResponsesTestFixture.collect(
        provider: provider, request: request)
      #expect(events.first == .started(providerResponseID: "resp_mapping"))
      #expect(events.last == .completed(.stop))

      let requests = await transport.requests()
      let sent = try #require(requests.first)
      #expect(sent.httpMethod == "POST")
      #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-platform-test")
      #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")

      let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
      #expect(body["model"] as? String == "gpt-test")
      #expect(body["stream"] as? Bool == true)
      #expect(body["store"] as? Bool == (mode == .serverManagedContinuation))
      #expect(body["max_output_tokens"] as? Int == 128)
      #expect(body["temperature"] as? Double == 0.5)
      #expect(body["parallel_tool_calls"] as? Bool == true)

      let toolChoice = try #require(body["tool_choice"] as? [String: Any])
      #expect(toolChoice["type"] as? String == "function")
      #expect(toolChoice["name"] as? String == "lookup_weather")
      let mappedTools = try #require(body["tools"] as? [[String: Any]])
      let mappedTool = try #require(mappedTools.first)
      #expect(mappedTool["type"] as? String == "function")
      #expect(mappedTool["parameters"] as? [String: Any] != nil)
      #expect(mappedTool["strict"] == nil)

      let input = try #require(body["input"] as? [[String: Any]])
      #expect(
        input.map { $0["type"] as? String } == [
          "message", "message", "message", "function_call", "function_call_output",
        ])
      let userContent = try #require(input[1]["content"] as? [[String: Any]])
      #expect(userContent.map { $0["type"] as? String } == ["input_text", "input_image"])
      #expect(userContent[1]["image_url"] as? String == imageURL.absoluteString)
      #expect(userContent[1]["detail"] as? String == "auto")

      let outputString = try #require(input[4]["output"] as? String)
      let outputData = Data(outputString.utf8)
      let outputObject = try #require(
        JSONSerialization.jsonObject(with: outputData) as? [String: Any]
      )
      #expect(outputObject["status"] as? String == "failure")
      #expect((outputObject["output"] as? [String: Any])?["message"] as? String == "offline")

      if mode == .localEphemeralReplay {
        #expect(body["previous_response_id"] == nil)
        #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
      } else {
        #expect(body["include"] == nil)
      }
    }
  }

  @Test
  func mapsRichToolResultTextAndSupportedImages() async throws {
    let httpsImage = try #require(URL(string: "https://images.example.test/result.webp"))
    let dataImage = try #require(URL(string: "data:image/png;base64,iVBORw0KGgo="))
    let call = ToolCall(
      id: ToolCallID(rawValue: "call_rich"),
      name: "lookup_weather",
      arguments: ["city": .string("Paris")]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .object(["temperature": .integer(18)]),
      content: [
        .text("The chart generated by the tool."),
        .image(ImageContent(sourceURL: httpsImage, mediaType: "image/webp")),
        .image(ImageContent(sourceURL: dataImage, mediaType: "image/png")),
      ]
    )
    let responseData = try OpenAIResponsesTestFixture.textStream(responseID: "resp_rich")
    let transport = TestOpenAIResponsesTransport(
      responses: [OpenAIResponsesTestFixture.response(data: responseData)]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-rich"),
      transport: transport
    )
    let request = OpenAIResponsesTestFixture.request(
      messages: [
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
      ],
      tools: [weatherTool()]
    )

    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: request)

    let sent = try #require(await transport.requests().first)
    let body = try OpenAIResponsesTestFixture.jsonObject(from: sent)
    let input = try #require(body["input"] as? [[String: Any]])
    let functionOutput = try #require(input.last)
    let content = try #require(functionOutput["output"] as? [[String: Any]])
    #expect(content.count == 4)
    #expect(
      content.map { $0["type"] as? String } == [
        "input_text", "input_text", "input_image", "input_image",
      ])

    let renderedOutput = try #require(content[0]["text"] as? String)
    let renderedData = Data(renderedOutput.utf8)
    let renderedObject = try #require(
      JSONSerialization.jsonObject(with: renderedData) as? [String: Any]
    )
    #expect(renderedObject["status"] as? String == "success")
    #expect((renderedObject["output"] as? [String: Any])?["temperature"] as? Int == 18)
    #expect(content[1]["text"] as? String == "The chart generated by the tool.")
    #expect(content[2]["image_url"] as? String == httpsImage.absoluteString)
    #expect(content[3]["image_url"] as? String == dataImage.absoluteString)
    #expect(content[2]["detail"] as? String == "auto")
  }

  @Test
  func rejectsUnsafeInvalidAndOversizedRichToolResultImages() async throws {
    let invalidImages = [
      ImageContent(
        sourceURL: try #require(URL(string: "file:///tmp/result.png")),
        mediaType: "image/png"
      ),
      ImageContent(
        sourceURL: try #require(URL(string: "http://images.example.test/result.png")),
        mediaType: "image/png"
      ),
      ImageContent(
        sourceURL: try #require(URL(string: "https://images.example.test/result.pdf")),
        mediaType: "application/pdf"
      ),
      ImageContent(
        sourceURL: try #require(URL(string: "data:image/jpeg;base64,iVBORw0KGgo=")),
        mediaType: "image/png"
      ),
      ImageContent(
        sourceURL: try #require(URL(string: "data:image/png;base64,not_base64")),
        mediaType: "image/png"
      ),
    ]

    for image in invalidImages {
      try await expectInvalidRichImage(
        image,
        configuration: OpenAIResponsesTestFixture.configuration()
      )
    }

    let oversizedURL = try #require(
      URL(string: "https://images.example.test/\(String(repeating: "a", count: 128)).png")
    )
    try await expectInvalidRichImage(
      ImageContent(sourceURL: oversizedURL, mediaType: "image/png"),
      configuration: OpenAIResponsesTestFixture.configuration(maximumInputValueBytes: 64)
    )
  }

  @Test
  func serverManagedContinuationSendsOnlyNewFunctionOutput() async throws {
    let firstResponse = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_server_1",
      callID: "call_server"
    )
    let secondResponse = try OpenAIResponsesTestFixture.textStream(responseID: "resp_server_2")
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: firstResponse),
        OpenAIResponsesTestFixture.response(data: secondResponse),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-server"),
      transport: transport
    )
    let tool = weatherTool()
    let original = Message(role: .user, content: [.text("Weather in Zürich?")])
    let firstRequest = OpenAIResponsesTestFixture.request(messages: [original], tools: [tool])
    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: firstRequest)

    let call = ToolCall(
      id: ToolCallID(rawValue: "call_server"),
      name: "lookup_weather",
      arguments: ["city": .string("Zürich")]
    )
    let output = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .object(["temperature": .integer(18)])
    )
    let secondRequest = OpenAIResponsesTestFixture.request(
      previousResponseID: "resp_server_1",
      messages: [
        original,
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(output)]),
      ],
      tools: [tool]
    )
    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: secondRequest)

    let requests = await transport.requests()
    #expect(requests.count == 2)
    let body = try OpenAIResponsesTestFixture.jsonObject(from: requests[1])
    #expect(body["store"] as? Bool == true)
    #expect(body["previous_response_id"] as? String == "resp_server_1")
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(input.count == 1)
    #expect(input[0]["type"] as? String == "function_call_output")
    #expect(input[0]["call_id"] as? String == "call_server")
  }

  @Test
  func localEphemeralContinuationReplaysOpaqueOutputsWithoutPreviousResponseID() async throws {
    let firstResponse = try OpenAIResponsesTestFixture.toolStream(
      responseID: "resp_local_1",
      callID: "call_local"
    )
    let secondResponse = try OpenAIResponsesTestFixture.textStream(responseID: "resp_local_2")
    let transport = TestOpenAIResponsesTransport(
      responses: [
        OpenAIResponsesTestFixture.response(data: firstResponse),
        OpenAIResponsesTestFixture.response(data: secondResponse),
      ]
    )
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(
        privacyMode: .localEphemeralReplay
      ),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-local"),
      transport: transport
    )
    let tool = weatherTool()
    let original = Message(role: .user, content: [.text("Weather in Zürich?")])
    let firstRequest = OpenAIResponsesTestFixture.request(messages: [original], tools: [tool])
    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: firstRequest)

    let call = ToolCall(
      id: ToolCallID(rawValue: "call_local"),
      name: "lookup_weather",
      arguments: ["city": .string("Zürich")]
    )
    let output = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .object(["temperature": .integer(18)])
    )
    let secondRequest = OpenAIResponsesTestFixture.request(
      previousResponseID: "resp_local_1",
      messages: [
        original,
        Message(role: .assistant, content: [.toolCall(call)]),
        Message(role: .tool, content: [.toolResult(output)]),
      ],
      tools: [tool]
    )
    _ = try await OpenAIResponsesTestFixture.collect(provider: provider, request: secondRequest)

    let requests = await transport.requests()
    let body = try OpenAIResponsesTestFixture.jsonObject(from: requests[1])
    #expect(body["store"] as? Bool == false)
    #expect(body["previous_response_id"] == nil)
    #expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
    let input = try #require(body["input"] as? [[String: Any]])
    #expect(
      input.map { $0["type"] as? String } == [
        "message", "reasoning", "function_call", "function_call_output",
      ])
    #expect(input.filter { $0["type"] as? String == "function_call" }.count == 1)
    #expect(input[1]["encrypted_content"] as? String == "encrypted-state")
  }

  @Test
  func exposesOnlyConfiguredModelsAndCapabilityIntersection() async throws {
    let transport = TestOpenAIResponsesTransport(responses: [])
    let provider = OpenAIResponsesProvider(
      configuration: try OpenAIResponsesTestFixture.configuration(),
      credentialProvider: TestOpenAICredentialProvider(key: "sk-models"),
      transport: transport
    )

    #expect(try await provider.availableModels() == [OpenAIResponsesTestFixture.model()])
    #expect(provider.descriptor.id == ProviderID(rawValue: "openai"))
    #expect(provider.descriptor.capabilities.contains(.streaming))
    #expect(!provider.descriptor.capabilities.contains(.structuredOutput))
  }

  private func weatherTool() -> ToolDefinition {
    ToolDefinition(
      name: "lookup_weather",
      description: "Look up weather for a city.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object(["city": .object(["type": .string("string")])]),
        "required": .array([.string("city")]),
        "additionalProperties": .boolean(false),
      ]
    )
  }

  private func expectInvalidRichImage(
    _ image: ImageContent,
    configuration: OpenAIResponsesConfiguration
  ) async throws {
    let call = ToolCall(
      id: ToolCallID(rawValue: "call_invalid_image"),
      name: "lookup_weather",
      arguments: [:]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .null,
      content: [.image(image)]
    )
    let transport = TestOpenAIResponsesTransport(responses: [])
    let provider = OpenAIResponsesProvider(
      configuration: configuration,
      credentialProvider: TestOpenAICredentialProvider(key: "sk-invalid-image"),
      transport: transport
    )

    do {
      _ = try await provider.stream(
        OpenAIResponsesTestFixture.request(
          messages: [
            Message(role: .assistant, content: [.toolCall(call)]),
            Message(role: .tool, content: [.toolResult(result)]),
          ],
          tools: [weatherTool()]
        )
      )
      Issue.record("Expected invalid rich tool-result image to be rejected.")
    } catch let error as OpenAIResponsesProviderError {
      #expect(error == .invalidRequest)
    } catch {
      Issue.record("Expected OpenAIResponsesProviderError.invalidRequest.")
    }
    #expect(await transport.requests().isEmpty)
  }
}
