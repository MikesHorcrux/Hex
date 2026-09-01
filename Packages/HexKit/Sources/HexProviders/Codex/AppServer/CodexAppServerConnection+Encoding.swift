import Foundation
import HexCore

extension CodexAppServerConnection {
  func encodedFrame(_ value: JSONValue) throws -> Data {
    guard
      CodexAppServerJSONValueValidator.isValid(
        value,
        maximumStringBytes: configuration.maximumMessageBytes,
        maximumEstimatedBytes: configuration.maximumMessageBytes
      )
    else {
      throw CodexAppServerConnectionError.limitExceeded
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    guard data.count <= configuration.maximumMessageBytes else {
      throw CodexAppServerConnectionError.limitExceeded
    }
    data.append(0x0A)
    return data
  }

  static func validMethod(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 46
          || byte == 47
          || byte == 95
      }
  }

  func sanitized(
    _ error: any Error,
    duringHandshake: Bool = false
  ) -> any Error {
    if error is CancellationError || Task.isCancelled {
      return CancellationError()
    }
    if let error = error as? CodexAppServerConnectionError {
      if duringHandshake {
        switch error {
        case .limitExceeded, .invalidConfiguration:
          return error
        case .requestTimedOut:
          return error
        default:
          return CodexAppServerConnectionError.handshakeFailed
        }
      }
      return error
    }
    return duringHandshake
      ? CodexAppServerConnectionError.handshakeFailed
      : CodexAppServerConnectionError.transportFailure
  }
}
