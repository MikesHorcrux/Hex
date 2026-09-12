/// Keep immutable prefixes reusable while a response grows. A chunk ends only at an existing
/// newline; joining the chunks with that separator recovers the provider's exact text.
nonisolated enum AgentStreamingTextLayout {
  static func chunks(_ text: String) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return stride(from: 0, to: lines.count, by: 32).map { start in
      lines[start..<min(start + 32, lines.count)].joined(separator: "\n")
    }
  }
}
