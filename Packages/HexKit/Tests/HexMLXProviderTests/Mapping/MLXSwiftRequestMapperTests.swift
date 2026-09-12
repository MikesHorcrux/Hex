import Foundation
import HexCore
import HexProviders
import MLXLMCommon
import Testing

@testable import HexMLXProvider

@Suite("MLX Swift request mapping")
struct MLXSwiftRequestMapperTests {
  @Test
  func preservesStructuredToolTranscriptAndCorrelation() throws {
    let call = HexCore.ToolCall(
      id: ToolCallID(rawValue: "call-1"),
      name: "read_file",
      arguments: ["path": .string("README.md")]
    )
    let result = ToolResult(
      toolCallID: call.id,
      status: .success,
      output: .object(["content": .string("hello")]),
      content: [.text("hello")]
    )
    let request = InferenceRequest(
      providerID: ProviderID(rawValue: "mlx.local"),
      modelID: ModelID(rawValue: "model"),
      messages: [
        Message(role: .developer, content: [.text("Be precise.")]),
        Message(role: .user, content: [.text("Read it.")]),
        Message(role: .assistant, content: [.text("I will."), .toolCall(call)]),
        Message(role: .tool, content: [.toolResult(result)]),
      ]
    )

    let messages = try MLXSwiftRequestMapper.messages(for: request)
    let raw = DefaultMessageGenerator().generate(messages: messages)

    #expect(messages.map(\.role) == [.system, .user, .assistant, .tool])
    #expect(messages.map(\.content).prefix(3) == ["Be precise.", "Read it.", "I will."])
    let assistantCalls = try #require(
      raw[2]["tool_calls"] as? [[String: any Sendable]]
    )
    let assistantCall = try #require(assistantCalls.first)
    #expect(assistantCall["id"] as? String == "call-1")
    let function = try #require(assistantCall["function"] as? [String: any Sendable])
    #expect(function["name"] as? String == "read_file")
    #expect(raw[3]["tool_call_id"] as? String == "call-1")
    #expect((raw[3]["content"] as? String)?.contains("hello") == true)
  }

  @Test
  func namedChoiceExposesOnlyTheSelectedSchema() throws {
    let request = InferenceRequest(
      providerID: ProviderID(rawValue: "mlx.local"),
      modelID: ModelID(rawValue: "model"),
      messages: [Message(role: .user, content: [.text("Use one tool.")])],
      tools: [
        tool(name: "first"),
        tool(name: "second"),
      ],
      toolChoice: .named("second")
    )

    let mappedSpecifications = try MLXSwiftRequestMapper.toolSpecifications(for: request)
    let specifications = try #require(mappedSpecifications)
    let specification = try #require(specifications.first)
    let function = try #require(specification["function"] as? [String: any Sendable])

    #expect(specifications.count == 1)
    #expect(function["name"] as? String == "second")
    let parameters = try #require(function["parameters"] as? [String: any Sendable])
    #expect(parameters["type"] as? String == "object")
  }

  @Test
  func convertsGeneratedArgumentsCanonicallyAndCreatesMissingCallID() throws {
    let generated = MLXLMCommon.ToolCall(
      function: .init(
        name: "calculate",
        arguments: [
          "integral_double": .double(2),
          "fraction": .double(2.5),
          "nested": .array([.bool(true), .null]),
        ]
      )
    )

    let mapped = try MLXSwiftRequestMapper.coreToolCall(generated)

    #expect(!mapped.id.rawValue.isEmpty)
    #expect(mapped.name == "calculate")
    #expect(mapped.arguments["integral_double"] == .integer(2))
    #expect(mapped.arguments["fraction"] == .number(2.5))
    #expect(mapped.arguments["nested"] == .array([.boolean(true), .null]))
  }

  @Test
  func rejectsImagesAndRoleContentMismatches() throws {
    let imageURL = URL(filePath: "/private/tmp/image.png")
    let invalidRequests = [
      InferenceRequest(
        providerID: ProviderID(rawValue: "mlx.local"),
        modelID: ModelID(rawValue: "model"),
        messages: [
          Message(
            role: .user,
            content: [.image(ImageContent(sourceURL: imageURL, mediaType: "image/png"))]
          )
        ]
      ),
      InferenceRequest(
        providerID: ProviderID(rawValue: "mlx.local"),
        modelID: ModelID(rawValue: "model"),
        messages: [
          Message(
            role: .user,
            content: [
              .toolCall(HexCore.ToolCall(name: "wrong_role", arguments: [:]))
            ]
          )
        ]
      ),
    ]

    for request in invalidRequests {
      #expect(throws: MLXLocalInferenceProviderError.invalidRequest) {
        _ = try MLXSwiftRequestMapper.messages(for: request)
      }
    }
  }

  private func tool(name: String) -> ToolDefinition {
    ToolDefinition(
      name: name,
      description: "A test tool.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([:]),
      ]
    )
  }
}
