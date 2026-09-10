import HexCore

public struct AgentRunBudget: Codable, Equatable, Sendable {
  public static let standard = AgentRunBudget(
    validatedMaxTurns: 32,
    maxToolCalls: 128,
    maxDiscoveredTools: 256,
    maxProviderEventsPerTurn: 4_096,
    maxInitialInputBytes: 4_194_304,
    maxConversationBytes: 4_194_304,
    maxTextBytesPerTurn: 1_048_576,
    maxSerializedOutputBytesPerTurn: 2_097_152,
    maxSerializedToolDefinitionsBytes: 1_048_576,
    maxToolResultBytes: 2_097_152,
    maxTotalToolResultBytes: 8_388_608,
    maxJournalEventBytes: 7_340_032,
    maxReportedTokens: 10_000_000
  )

  public let maxTurns: Int
  public let maxToolCalls: Int
  public let maxDiscoveredTools: Int
  public let maxProviderEventsPerTurn: Int
  public let maxInitialInputBytes: Int
  public let maxConversationBytes: Int
  public let maxTextBytesPerTurn: Int
  public let maxSerializedOutputBytesPerTurn: Int
  public let maxSerializedToolDefinitionsBytes: Int
  public let maxToolResultBytes: Int
  public let maxTotalToolResultBytes: Int
  public let maxJournalEventBytes: Int
  public let maxReportedTokens: UInt64

  public init(
    maxTurns: Int = 32,
    maxToolCalls: Int = 128,
    maxDiscoveredTools: Int = 256,
    maxProviderEventsPerTurn: Int = 4_096,
    // Saved continuations must fit the same bounded envelope as an active conversation.
    maxInitialInputBytes: Int = 4_194_304,
    maxConversationBytes: Int = 4_194_304,
    maxTextBytesPerTurn: Int = 1_048_576,
    maxSerializedOutputBytesPerTurn: Int = 2_097_152,
    maxSerializedToolDefinitionsBytes: Int = 1_048_576,
    maxToolResultBytes: Int = 2_097_152,
    maxTotalToolResultBytes: Int = 8_388_608,
    maxJournalEventBytes: Int = 7_340_032,
    maxReportedTokens: UInt64 = 10_000_000
  ) throws {
    self.init(
      validatedMaxTurns: maxTurns,
      maxToolCalls: maxToolCalls,
      maxDiscoveredTools: maxDiscoveredTools,
      maxProviderEventsPerTurn: maxProviderEventsPerTurn,
      maxInitialInputBytes: maxInitialInputBytes,
      maxConversationBytes: maxConversationBytes,
      maxTextBytesPerTurn: maxTextBytesPerTurn,
      maxSerializedOutputBytesPerTurn: maxSerializedOutputBytesPerTurn,
      maxSerializedToolDefinitionsBytes: maxSerializedToolDefinitionsBytes,
      maxToolResultBytes: maxToolResultBytes,
      maxTotalToolResultBytes: maxTotalToolResultBytes,
      maxJournalEventBytes: maxJournalEventBytes,
      maxReportedTokens: maxReportedTokens
    )
    try validate()
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      maxTurns: container.decode(Int.self, forKey: .maxTurns),
      maxToolCalls: container.decode(Int.self, forKey: .maxToolCalls),
      maxDiscoveredTools: container.decode(Int.self, forKey: .maxDiscoveredTools),
      maxProviderEventsPerTurn: container.decode(Int.self, forKey: .maxProviderEventsPerTurn),
      maxInitialInputBytes: container.decode(Int.self, forKey: .maxInitialInputBytes),
      maxConversationBytes: container.decode(Int.self, forKey: .maxConversationBytes),
      maxTextBytesPerTurn: container.decode(Int.self, forKey: .maxTextBytesPerTurn),
      maxSerializedOutputBytesPerTurn: container.decode(
        Int.self,
        forKey: .maxSerializedOutputBytesPerTurn
      ),
      maxSerializedToolDefinitionsBytes: container.decode(
        Int.self,
        forKey: .maxSerializedToolDefinitionsBytes
      ),
      maxToolResultBytes: container.decode(Int.self, forKey: .maxToolResultBytes),
      maxTotalToolResultBytes: container.decode(Int.self, forKey: .maxTotalToolResultBytes),
      maxJournalEventBytes: container.decode(Int.self, forKey: .maxJournalEventBytes),
      maxReportedTokens: container.decode(UInt64.self, forKey: .maxReportedTokens)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(maxTurns, forKey: .maxTurns)
    try container.encode(maxToolCalls, forKey: .maxToolCalls)
    try container.encode(maxDiscoveredTools, forKey: .maxDiscoveredTools)
    try container.encode(maxProviderEventsPerTurn, forKey: .maxProviderEventsPerTurn)
    try container.encode(maxInitialInputBytes, forKey: .maxInitialInputBytes)
    try container.encode(maxConversationBytes, forKey: .maxConversationBytes)
    try container.encode(maxTextBytesPerTurn, forKey: .maxTextBytesPerTurn)
    try container.encode(maxSerializedOutputBytesPerTurn, forKey: .maxSerializedOutputBytesPerTurn)
    try container.encode(
      maxSerializedToolDefinitionsBytes,
      forKey: .maxSerializedToolDefinitionsBytes
    )
    try container.encode(maxToolResultBytes, forKey: .maxToolResultBytes)
    try container.encode(maxTotalToolResultBytes, forKey: .maxTotalToolResultBytes)
    try container.encode(maxJournalEventBytes, forKey: .maxJournalEventBytes)
    try container.encode(maxReportedTokens, forKey: .maxReportedTokens)
  }

  func validate() throws {
    try validate(maxTurns, named: "maxTurns", upperBound: 256)
    try validate(maxToolCalls, named: "maxToolCalls", upperBound: 2_048)
    try validate(maxDiscoveredTools, named: "maxDiscoveredTools", upperBound: 4_096)
    try validate(
      maxProviderEventsPerTurn,
      named: "maxProviderEventsPerTurn",
      upperBound: 100_000
    )
    try validate(maxInitialInputBytes, named: "maxInitialInputBytes", upperBound: 67_108_864)
    try validate(maxConversationBytes, named: "maxConversationBytes", upperBound: 536_870_912)
    try validate(maxTextBytesPerTurn, named: "maxTextBytesPerTurn", upperBound: 16_777_216)
    try validate(
      maxSerializedOutputBytesPerTurn,
      named: "maxSerializedOutputBytesPerTurn",
      upperBound: 67_108_864
    )
    try validate(
      maxSerializedToolDefinitionsBytes,
      named: "maxSerializedToolDefinitionsBytes",
      upperBound: 67_108_864
    )
    try validate(maxToolResultBytes, named: "maxToolResultBytes", upperBound: 67_108_864)
    try validate(
      maxTotalToolResultBytes,
      named: "maxTotalToolResultBytes",
      upperBound: 268_435_456
    )
    try validate(maxJournalEventBytes, named: "maxJournalEventBytes", upperBound: 268_435_456)
    guard maxInitialInputBytes <= maxConversationBytes else {
      throw AgentRuntimeError.invalidConfiguration(
        "maxInitialInputBytes cannot exceed maxConversationBytes."
      )
    }
    guard maxToolResultBytes <= maxTotalToolResultBytes else {
      throw AgentRuntimeError.invalidConfiguration(
        "maxToolResultBytes cannot exceed maxTotalToolResultBytes."
      )
    }
    guard maxTextBytesPerTurn <= maxSerializedOutputBytesPerTurn else {
      throw AgentRuntimeError.invalidConfiguration(
        "maxTextBytesPerTurn cannot exceed maxSerializedOutputBytesPerTurn."
      )
    }
    try validateCombinedBytes(
      [maxConversationBytes, maxSerializedToolDefinitionsBytes, 65_536],
      fitWithin: maxJournalEventBytes,
      message: "Conversation and tool definition budgets must fit the journal event envelope."
    )
    try validateCombinedBytes(
      [maxToolResultBytes, 65_536],
      fitWithin: maxJournalEventBytes,
      message: "The tool result budget must fit the journal event envelope."
    )
    try validateCombinedBytes(
      [maxSerializedOutputBytesPerTurn, 65_536],
      fitWithin: maxJournalEventBytes,
      message: "The provider output budget must fit the journal event envelope."
    )
    guard maxReportedTokens > 0, maxReportedTokens <= 1_000_000_000 else {
      throw AgentRuntimeError.invalidConfiguration(
        "maxReportedTokens must be between 1 and 1000000000."
      )
    }
  }

  private init(
    validatedMaxTurns maxTurns: Int,
    maxToolCalls: Int,
    maxDiscoveredTools: Int,
    maxProviderEventsPerTurn: Int,
    maxInitialInputBytes: Int,
    maxConversationBytes: Int,
    maxTextBytesPerTurn: Int,
    maxSerializedOutputBytesPerTurn: Int,
    maxSerializedToolDefinitionsBytes: Int,
    maxToolResultBytes: Int,
    maxTotalToolResultBytes: Int,
    maxJournalEventBytes: Int,
    maxReportedTokens: UInt64
  ) {
    self.maxTurns = maxTurns
    self.maxToolCalls = maxToolCalls
    self.maxDiscoveredTools = maxDiscoveredTools
    self.maxProviderEventsPerTurn = maxProviderEventsPerTurn
    self.maxInitialInputBytes = maxInitialInputBytes
    self.maxConversationBytes = maxConversationBytes
    self.maxTextBytesPerTurn = maxTextBytesPerTurn
    self.maxSerializedOutputBytesPerTurn = maxSerializedOutputBytesPerTurn
    self.maxSerializedToolDefinitionsBytes = maxSerializedToolDefinitionsBytes
    self.maxToolResultBytes = maxToolResultBytes
    self.maxTotalToolResultBytes = maxTotalToolResultBytes
    self.maxJournalEventBytes = maxJournalEventBytes
    self.maxReportedTokens = maxReportedTokens
  }

  private func validate(_ value: Int, named name: String, upperBound: Int) throws {
    guard value > 0, value <= upperBound else {
      throw AgentRuntimeError.invalidConfiguration(
        "\(name) must be between 1 and \(upperBound)."
      )
    }
  }

  private func validateCombinedBytes(
    _ values: [Int],
    fitWithin limit: Int,
    message: String
  ) throws {
    var total = 0
    for value in values {
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else {
        throw AgentRuntimeError.invalidConfiguration(message)
      }
      total = next
    }
    guard total <= limit else {
      throw AgentRuntimeError.invalidConfiguration(message)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case maxTurns
    case maxToolCalls
    case maxDiscoveredTools
    case maxProviderEventsPerTurn
    case maxInitialInputBytes
    case maxConversationBytes
    case maxTextBytesPerTurn
    case maxSerializedOutputBytesPerTurn
    case maxSerializedToolDefinitionsBytes
    case maxToolResultBytes
    case maxTotalToolResultBytes
    case maxJournalEventBytes
    case maxReportedTokens
  }
}
