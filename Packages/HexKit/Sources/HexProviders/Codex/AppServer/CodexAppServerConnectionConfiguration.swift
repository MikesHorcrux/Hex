import Foundation
import HexCore

/// Bounded stable-protocol configuration for one Codex app-server connection.
public struct CodexAppServerConnectionConfiguration: Equatable, Sendable {
  public let clientName: String
  public let clientTitle: String
  public let clientVersion: String
  public let maximumMessageBytes: Int
  public let maximumPendingRequests: Int
  public let requestTimeoutMilliseconds: UInt64

  public init(
    clientName: String = "hex",
    clientTitle: String = "Hex",
    clientVersion: String,
    maximumMessageBytes: Int = 1_048_576,
    maximumPendingRequests: Int = 32,
    requestTimeoutMilliseconds: UInt64 = 30_000
  ) throws {
    guard Self.isValidClientName(clientName),
      Self.isValidPresentationText(clientTitle, maximumBytes: 128),
      Self.isValidVersion(clientVersion),
      (1_024...8_388_608).contains(maximumMessageBytes),
      (1...64).contains(maximumPendingRequests),
      (1...300_000).contains(requestTimeoutMilliseconds)
    else {
      throw CodexAppServerConnectionError.invalidConfiguration
    }
    self.clientName = clientName
    self.clientTitle = clientTitle
    self.clientVersion = clientVersion
    self.maximumMessageBytes = maximumMessageBytes
    self.maximumPendingRequests = maximumPendingRequests
    self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
  }

  var initializeParameters: JSONValue {
    .object([
      "clientInfo": .object([
        "name": .string(clientName),
        "title": .string(clientTitle),
        "version": .string(clientVersion),
      ])
    ])
  }

  var maximumReadBytes: Int {
    max(maximumMessageBytes, 65_536)
  }

  private static func isValidClientName(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (97...122).contains(byte)
          || byte == 95
      }
  }

  private static func isValidVersion(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 43
          || byte == 45
          || byte == 46
      }
  }

  private static func isValidPresentationText(_ value: String, maximumBytes: Int) -> Bool {
    !value.isEmpty && value.utf8.count <= maximumBytes
      && !value.unicodeScalars.contains { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
          true
        default:
          false
        }
      }
  }
}
