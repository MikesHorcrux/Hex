import Foundation
import HexCore

struct InferenceTurnAccumulator: Sendable {
  private let budget: AgentRunBudget
  private let allowedToolNames: Set<String>
  private let priorToolCallIDs: Set<ToolCallID>
  private let remainingToolCalls: Int
  private let remainingReportedTokens: UInt64
  private let allowsParallelToolCalls: Bool

  private var eventCount = 0
  private var textByteCount = 0
  private var serializedByteCount = 0
  private var didStart = false
  private var providerResponseID: String?
  private var completedReason: InferenceStopReason?
  private var usage: InferenceUsage?
  private var reportedTokens: UInt64 = 0
  private var assistantContent: [MessageContent] = []
  private var toolCalls: [ToolCall] = []
  private var currentToolCallIDs: Set<ToolCallID> = []

  init(
    budget: AgentRunBudget,
    allowedToolNames: Set<String>,
    priorToolCallIDs: Set<ToolCallID>,
    remainingToolCalls: Int,
    remainingReportedTokens: UInt64,
    allowsParallelToolCalls: Bool
  ) {
    self.budget = budget
    self.allowedToolNames = allowedToolNames
    self.priorToolCallIDs = priorToolCallIDs
    self.remainingToolCalls = remainingToolCalls
    self.remainingReportedTokens = remainingReportedTokens
    self.allowsParallelToolCalls = allowsParallelToolCalls
  }

  mutating func accept(_ event: InferenceStreamEvent) throws {
    guard completedReason == nil else {
      throw AgentRuntimeError.protocolViolation(
        "The inference provider emitted an event after completion."
      )
    }
    guard eventCount < budget.maxProviderEventsPerTurn else {
      throw AgentRuntimeError.budgetExceeded("Provider event budget exceeded for this turn.")
    }

    eventCount += 1
    try recordSerializedBytes(for: event)

    if !didStart {
      guard case .started = event else {
        throw AgentRuntimeError.protocolViolation(
          "The first inference event must be started."
        )
      }
    }

    switch event {
    case .started(let responseID):
      guard !didStart, eventCount == 1 else {
        throw AgentRuntimeError.protocolViolation(
          "The inference provider emitted more than one started event."
        )
      }
      if let responseID,
        responseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw AgentRuntimeError.protocolViolation(
          "A provider response ID must be nonempty when supplied."
        )
      }
      didStart = true
      providerResponseID = responseID

    case .textDelta(let text):
      try requireStarted()
      guard !text.isEmpty else {
        throw AgentRuntimeError.protocolViolation("The provider emitted an empty text delta.")
      }
      try recordTextBytes(text.utf8.count)
      appendText(text)

    case .reasoningSummaryDelta(let text):
      try requireStarted()
      guard !text.isEmpty else {
        throw AgentRuntimeError.protocolViolation(
          "The provider emitted an empty reasoning summary delta."
        )
      }
      try recordTextBytes(text.utf8.count)

    case .toolCall(let call):
      try requireStarted()
      guard toolCalls.count < remainingToolCalls else {
        throw AgentRuntimeError.budgetExceeded("Tool call budget exceeded.")
      }
      guard !call.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentRuntimeError.protocolViolation("The provider emitted an empty tool call ID.")
      }
      guard !call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AgentRuntimeError.protocolViolation("The provider emitted an empty tool name.")
      }
      guard allowedToolNames.contains(call.name) else {
        throw AgentRuntimeError.protocolViolation("The provider requested an unknown tool.")
      }
      guard
        !priorToolCallIDs.contains(call.id),
        currentToolCallIDs.insert(call.id).inserted
      else {
        throw AgentRuntimeError.protocolViolation("The provider reused a tool call ID.")
      }
      guard toolCalls.isEmpty || allowsParallelToolCalls else {
        throw AgentRuntimeError.unsupportedCapability(.parallelToolCalling)
      }
      toolCalls.append(call)
      assistantContent.append(.toolCall(call))

    case .usage(let value):
      try requireStarted()
      guard usage == nil else {
        throw AgentRuntimeError.protocolViolation(
          "The inference provider emitted more than one usage event."
        )
      }
      guard
        value.cachedInputTokens <= value.inputTokens,
        value.reasoningTokens <= value.outputTokens
      else {
        throw AgentRuntimeError.protocolViolation(
          "Detailed token counts must be subsets of their reported totals."
        )
      }
      let total = try reportedTokenTotal(for: value)
      guard total <= remainingReportedTokens else {
        throw AgentRuntimeError.budgetExceeded("Reported token budget exceeded.")
      }
      usage = value
      reportedTokens = total

    case .completed(let reason):
      try requireStarted()
      switch reason {
      case .toolCalls:
        guard !toolCalls.isEmpty else {
          throw AgentRuntimeError.protocolViolation(
            "A toolCalls stop reason requires at least one tool call."
          )
        }
      case .stop, .length, .contentFilter, .other:
        guard toolCalls.isEmpty else {
          throw AgentRuntimeError.protocolViolation(
            "Tool calls require the toolCalls stop reason."
          )
        }
      }
      completedReason = reason
    }
  }

  mutating func finish() throws -> (
    assistantMessage: Message,
    toolCalls: [ToolCall],
    usage: InferenceUsage?,
    stopReason: InferenceStopReason,
    providerResponseID: String?,
    reportedTokens: UInt64
  ) {
    guard didStart else {
      throw AgentRuntimeError.protocolViolation(
        "The inference stream ended without a started event."
      )
    }
    guard let completedReason else {
      throw AgentRuntimeError.protocolViolation(
        "The inference stream ended without a completed event."
      )
    }
    guard !assistantContent.isEmpty else {
      throw AgentRuntimeError.protocolViolation("The inference provider returned empty output.")
    }

    return (
      Message(role: .assistant, content: assistantContent),
      toolCalls,
      usage,
      completedReason,
      providerResponseID,
      reportedTokens
    )
  }

  private mutating func appendText(_ text: String) {
    if let lastIndex = assistantContent.indices.last,
      case .text(let existingText) = assistantContent[lastIndex]
    {
      assistantContent[lastIndex] = .text(existingText + text)
    } else {
      assistantContent.append(.text(text))
    }
  }

  private func requireStarted() throws {
    guard didStart else {
      throw AgentRuntimeError.protocolViolation(
        "The inference provider emitted output before started."
      )
    }
  }

  private mutating func recordSerializedBytes(for event: InferenceStreamEvent) throws {
    let encoded: Data
    do {
      encoded = try JSONEncoder().encode(event)
    } catch {
      throw AgentRuntimeError.protocolViolation(
        "The inference provider emitted output that cannot be serialized."
      )
    }
    serializedByteCount = try adding(
      encoded.count,
      to: serializedByteCount,
      limit: budget.maxSerializedOutputBytesPerTurn,
      message: "Serialized provider output budget exceeded for this turn."
    )
  }

  private mutating func recordTextBytes(_ count: Int) throws {
    textByteCount = try adding(
      count,
      to: textByteCount,
      limit: budget.maxTextBytesPerTurn,
      message: "Provider text budget exceeded for this turn."
    )
  }

  private func adding(_ value: Int, to current: Int, limit: Int, message: String) throws -> Int {
    let (sum, overflow) = current.addingReportingOverflow(value)
    guard !overflow, sum <= limit else {
      throw AgentRuntimeError.budgetExceeded(message)
    }
    return sum
  }

  private func reportedTokenTotal(for usage: InferenceUsage) throws -> UInt64 {
    var total: UInt64 = 0
    for value in [usage.inputTokens, usage.outputTokens] {
      let (next, overflow) = total.addingReportingOverflow(value)
      guard !overflow else {
        throw AgentRuntimeError.budgetExceeded("Reported token count overflowed.")
      }
      total = next
    }
    return total
  }
}
