import Foundation
import HexCore

enum MCPSSEMessageDecoder {
  static func decode(
    _ data: Data,
    maximumEvents: Int,
    maximumMessageBytes: Int
  ) throws -> [JSONValue] {
    guard data.count <= maximumMessageBytes else {
      throw MCPClientSessionError.limitExceeded
    }
    guard let source = String(data: data, encoding: .utf8) else {
      throw MCPClientSessionError.protocolViolation
    }

    var messages: [JSONValue] = []
    var dataLines: [Substring] = []
    var eventCount = 0
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty {
        if !dataLines.isEmpty {
          eventCount += 1
          guard eventCount <= maximumEvents else {
            throw MCPClientSessionError.limitExceeded
          }
          let payload = dataLines.joined(separator: "\n")
          dataLines.removeAll(keepingCapacity: true)
          if !payload.isEmpty {
            try appendMessage(payload, to: &messages, maximumMessageBytes: maximumMessageBytes)
          }
        }
        continue
      }
      if line.first == ":" { continue }
      if line == "data" {
        dataLines.append(Substring(""))
        continue
      }
      guard line.hasPrefix("data:") else { continue }
      var value = line.dropFirst(5)
      if value.first == " " { value = value.dropFirst() }
      dataLines.append(value)
    }
    if !dataLines.isEmpty {
      eventCount += 1
      guard eventCount <= maximumEvents else {
        throw MCPClientSessionError.limitExceeded
      }
      let payload = dataLines.joined(separator: "\n")
      if !payload.isEmpty {
        try appendMessage(payload, to: &messages, maximumMessageBytes: maximumMessageBytes)
      }
    }
    return messages
  }

  private static func appendMessage(
    _ payload: String,
    to messages: inout [JSONValue],
    maximumMessageBytes: Int
  ) throws {
    let messageData = Data(payload.utf8)
    guard messageData.count <= maximumMessageBytes else {
      throw MCPClientSessionError.limitExceeded
    }
    try MCPJSONStructuralPreflight.validateObjectRoot(messageData)
    do {
      messages.append(try JSONDecoder().decode(JSONValue.self, from: messageData))
    } catch {
      throw MCPClientSessionError.protocolViolation
    }
  }
}
