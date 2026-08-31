import HexCore

public struct InferenceTurn: Codable, Equatable, Sendable {
  public let number: Int
  public let requestID: InferenceRequestID
  public let providerResponseID: String?
  public let assistantMessage: Message
  public let toolResults: [ToolResult]
  public let usage: InferenceUsage?
  public let stopReason: InferenceStopReason

  public init(
    number: Int,
    requestID: InferenceRequestID,
    providerResponseID: String?,
    assistantMessage: Message,
    toolResults: [ToolResult],
    usage: InferenceUsage?,
    stopReason: InferenceStopReason
  ) {
    self.number = number
    self.requestID = requestID
    self.providerResponseID = providerResponseID
    self.assistantMessage = assistantMessage
    self.toolResults = toolResults
    self.usage = usage
    self.stopReason = stopReason
  }
}
