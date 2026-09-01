import HexCore

public enum MLXInferenceEngineEvent: Equatable, Sendable {
  case textDelta(String)
  case toolCall(ToolCall)
  case completed(usage: InferenceUsage, stopReason: InferenceStopReason)
}
