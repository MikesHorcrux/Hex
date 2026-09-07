import Testing

@testable import Hex

@Suite("Incremental streaming text layout")
struct AgentStreamingTextLayoutTests {
  @Test
  func allLinesAndWhitespaceSurviveChunking() {
    let text = (1...500).map { "\($0). Hex delivers once." }.joined(separator: "\n") + "\n\n"
    let chunks = AgentStreamingTextLayout.chunks(text)
    #expect(chunks.count == 16)
    #expect(chunks.joined(separator: "\n") == text)
    #expect(
      chunks.allSatisfy { $0.split(separator: "\n", omittingEmptySubsequences: false).count <= 32 })
    #expect(AgentStreamingTextLayout.chunks("") == [""])
    #expect(AgentStreamingTextLayout.chunks("single line") == ["single line"])
  }

  @Test
  func appendingTokensKeepsCompletedPrefixesStable() {
    let prefix = (1...64).map { "Line \($0) 🐑" }.joined(separator: "\n")
    let before = AgentStreamingTextLayout.chunks(prefix + "\nPartial")
    let after = AgentStreamingTextLayout.chunks(prefix + "\nPartial reply\n")
    #expect(Array(before.prefix(2)) == Array(after.prefix(2)))
    #expect(after.last == "Partial reply\n")
  }
}
