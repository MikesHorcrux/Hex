import Foundation
import HexCore
import Testing

@testable import HexRuntime

@Suite("Runtime context configuration")
struct AgentContextConfigurationTests {
  @Test
  func legacyBudgetOnlyConfigurationKeepsItsCanonicalRepresentation() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let budget = try encoder.encode(AgentRunBudget.standard)
    let legacy = Data("{\"budget\":".utf8) + budget + Data("}".utf8)
    let restored = try JSONDecoder().decode(AgentRuntimeConfiguration.self, from: legacy)
    #expect(restored.context == AgentContextConfiguration())
    #expect(try encoder.encode(restored) == legacy)
  }

  @Test
  func customLimitsRoundTripAndInvalidDecodedLimitsAreRejected() throws {
    let configuration = AgentRuntimeConfiguration(
      context: AgentContextConfiguration(
        fallbackContextWindow: 65_536, maximumSummaryTokens: 4_096, maximumSummaryCalls: 4))
    let bytes = try JSONEncoder().encode(configuration)
    #expect(try JSONDecoder().decode(AgentRuntimeConfiguration.self, from: bytes) == configuration)
    let invalid = AgentRuntimeConfiguration(
      context: AgentContextConfiguration(maximumSummaryCalls: 0))
    #expect(throws: AgentRuntimeError.self) {
      try JSONDecoder().decode(AgentRuntimeConfiguration.self, from: JSONEncoder().encode(invalid))
    }
  }
}
