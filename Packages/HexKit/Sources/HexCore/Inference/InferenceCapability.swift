public enum InferenceCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case textInput = "text_input"
  case imageInput = "image_input"
  case streaming
  case toolCalling = "tool_calling"
  case parallelToolCalling = "parallel_tool_calling"
  case structuredOutput = "structured_output"
  case reasoningSummary = "reasoning_summary"
}
