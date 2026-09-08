import HexCore

/// Shared, side-effect-free text presentation for live and retained run output.
nonisolated enum AgentMessagePresentation {
  static func text(_ message: Message) -> String {
    message.content.map { content in
      switch content {
      case .text(let text): text
      case .toolCall(let call): "Tool call · \(call.name)"
      case .toolResult(let result): toolResultText(result)
      case .image: "[Image]"
      }
    }.joined(separator: "\n")
  }

  static func toolResultText(_ result: ToolResult) -> String {
    if let reason = result.notExecutedReason {
      let explanation =
        switch reason {
        case .cancelled: "The run was cancelled before this tool started."
        case .runStopped: "The run stopped before this tool started."
        case .interrupted: "The agent stopped before this tool started."
        case .invalidArguments: "The tool arguments were invalid, so it did not run."
        case .authorizationDenied: "This action was not approved, so it did not run."
        }
      return "Not run\n\(explanation)"
    }
    let status =
      result.requiresUserAttention
      ? "Needs your attention" : (result.status == .success ? "Succeeded" : "Failed")
    if !result.artifacts.isEmpty {
      let preview: String
      if case .object(let values) = result.output,
        case .string(let text) = values["output"] ?? values["preview"]
      {
        preview = text
      } else {
        preview = HexJSONValueFormatter.string(from: result.output)
      }
      let snippet = String(preview.prefix(1_200))
      let completeness =
        result.artifacts.allSatisfy(\.isComplete)
        ? "Output saved" : "Partial output saved"
      return "\(status) · \(completeness)\n\(snippet)"
        + (preview.count > snippet.count ? "\n… Open saved output to read more." : "")
    }
    return "\(status) · \(HexJSONValueFormatter.string(from: result.output))"
  }
}
