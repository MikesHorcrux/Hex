import Foundation
import HexCore
import Testing

@Suite("Tool contracts")
struct ToolContractTests {
  @Test
  func roundTripsEveryToolChoice() throws {
    let choices: [ToolChoice] = [
      .automatic,
      .none,
      .required,
      .named("read_file"),
    ]

    for choice in choices {
      #expect(try roundTrip(choice) == choice)
    }
  }

  @Test
  func preservesDefinitionsCallsAndResults() throws {
    let definition = ToolDefinition(
      name: "read_file",
      description: "Read a UTF-8 file",
      inputSchema: [
        "type": .string("object"),
        "required": .array([.string("path")]),
      ]
    )
    let call = ToolCall(
      id: ToolCallID(rawValue: "call-read-1"),
      name: definition.name,
      arguments: ["path": .string("/tmp/example.txt")]
    )
    let statuses = ToolResultStatus.allCases

    #expect(try roundTrip(definition) == definition)
    #expect(try roundTrip(call) == call)
    #expect(statuses == [.success, .failure])

    for status in statuses {
      let result = ToolResult(
        toolCallID: call.id,
        status: status,
        output: status == .success ? .string("contents") : .string("not readable")
      )
      #expect(try roundTrip(result) == result)
    }
  }

  @Test
  func preservesExecutionContext() throws {
    let context = ToolExecutionContext(
      runID: AgentRunID(),
      workingDirectory: URL(fileURLWithPath: "/tmp/hex", isDirectory: true)
    )

    #expect(context.workingDirectory?.isFileURL == true)
    #expect(context.workingDirectory?.path.hasPrefix("/") == true)
    #expect(try roundTrip(context) == context)
  }

  private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
  }
}
