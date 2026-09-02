enum MCPHTTPHeaderValidator {
  private static let reservedNames = Set([
    "accept",
    "connection",
    "content-length",
    "content-type",
    "host",
    "mcp-protocol-version",
    "mcp-session-id",
    "origin",
    "transfer-encoding",
  ])

  static func validate(_ headers: [String: String]) throws -> [String: String] {
    guard headers.count <= 64 else {
      throw MCPClientSessionError.limitExceeded
    }
    var normalized: [String: String] = [:]
    var totalBytes = 0
    for (name, value) in headers {
      let lowercaseName = name.lowercased()
      guard
        !lowercaseName.isEmpty,
        lowercaseName.utf8.count <= 128,
        lowercaseName.utf8.allSatisfy(Self.isHeaderNameByte),
        !reservedNames.contains(lowercaseName),
        value.utf8.count <= 16 * 1_024,
        value.utf8.allSatisfy(Self.isHeaderValueByte),
        normalized[lowercaseName] == nil
      else {
        throw MCPClientSessionError.protocolViolation
      }
      let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(
        lowercaseName.utf8.count + value.utf8.count + 2
      )
      guard !overflowed, nextTotal <= 64 * 1_024 else {
        throw MCPClientSessionError.limitExceeded
      }
      normalized[lowercaseName] = value
      totalBytes = nextTotal
    }
    return normalized
  }

  private static func isHeaderNameByte(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
      || (65...90).contains(byte)
      || (97...122).contains(byte)
      || byte == 33
      || byte == 35
      || byte == 36
      || byte == 37
      || byte == 38
      || byte == 39
      || byte == 42
      || byte == 43
      || byte == 45
      || byte == 46
      || byte == 94
      || byte == 95
      || byte == 96
      || byte == 124
      || byte == 126
  }

  private static func isHeaderValueByte(_ byte: UInt8) -> Bool {
    byte == 9 || (32...126).contains(byte)
  }
}
