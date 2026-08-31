import Foundation
import HexCore

enum MLXRequestContentValidator {
  static let maximumRequestBytes = 16 * 1_024 * 1_024
  static let maximumJSONDepth = 64
  static let maximumJSONNodes = 100_000

  static func validate(_ request: InferenceRequest) -> Bool {
    var remainingBytes = maximumRequestBytes
    var remainingNodes = maximumJSONNodes
    var unresolvedToolCalls = Set<ToolCallID>()
    var seenToolCalls = Set<ToolCallID>()

    for message in request.messages {
      guard consumeNode(remainingNodes: &remainingNodes) else {
        return false
      }
      switch message.role {
      case .system, .developer, .user:
        guard
          validateTextMessage(
            message,
            remainingBytes: &remainingBytes,
            remainingNodes: &remainingNodes
          )
        else {
          return false
        }

      case .assistant:
        guard
          validateAssistantMessage(
            message,
            unresolvedToolCalls: &unresolvedToolCalls,
            seenToolCalls: &seenToolCalls,
            remainingBytes: &remainingBytes,
            remainingNodes: &remainingNodes
          )
        else {
          return false
        }

      case .tool:
        guard
          validateToolMessage(
            message,
            unresolvedToolCalls: &unresolvedToolCalls,
            remainingBytes: &remainingBytes,
            remainingNodes: &remainingNodes
          )
        else {
          return false
        }
      }
    }
    guard unresolvedToolCalls.isEmpty else {
      return false
    }

    let toolNames = request.tools.map(\.name)
    guard Set(toolNames).count == toolNames.count else {
      return false
    }
    for definition in request.tools {
      guard
        validateToolDefinition(
          definition,
          remainingBytes: &remainingBytes,
          remainingNodes: &remainingNodes
        )
      else {
        return false
      }
    }

    guard
      let encodedRequest = try? JSONEncoder().encode(request),
      encodedRequest.count <= maximumRequestBytes
    else {
      return false
    }
    return true
  }
}
