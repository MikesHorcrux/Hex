import CryptoKit
import Foundation

public enum AgentTaskOperationFingerprint {
  public static func data(for call: ToolCall) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let value = JSONValue.object(["name": .string(call.name), "arguments": .object(call.arguments)])
    return Data(SHA256.hash(data: try encoder.encode(value)))
  }
}
