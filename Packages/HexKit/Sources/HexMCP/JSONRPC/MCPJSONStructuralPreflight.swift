import Foundation

struct MCPJSONStructuralPreflight {
  private let bytes: [UInt8]
  private let maximumDepth: Int
  private let maximumNodes: Int
  private var index = 0
  private var nodeCount = 0

  static func validateObjectRoot(
    _ data: Data,
    maximumDepth: Int = 64,
    maximumNodes: Int = 100_000
  ) throws {
    var validator = MCPJSONStructuralPreflight(
      bytes: Array(data),
      maximumDepth: maximumDepth,
      maximumNodes: maximumNodes
    )
    validator.skipWhitespace()
    guard validator.peek() == 0x7B else {
      throw MCPClientSessionError.protocolViolation
    }
    try validator.parseValue(depth: 1)
    validator.skipWhitespace()
    guard validator.index == validator.bytes.count else {
      throw MCPClientSessionError.protocolViolation
    }
  }

  private mutating func parseValue(depth: Int) throws {
    guard depth <= maximumDepth, nodeCount < maximumNodes else {
      throw MCPClientSessionError.limitExceeded
    }
    nodeCount += 1
    skipWhitespace()
    guard let byte = peek() else {
      throw MCPClientSessionError.protocolViolation
    }
    switch byte {
    case 0x7B:
      try parseObject(depth: depth)
    case 0x5B:
      try parseArray(depth: depth)
    case 0x22:
      _ = try parseString(decodingValue: false)
    case 0x74:
      try parseLiteral([0x74, 0x72, 0x75, 0x65])
    case 0x66:
      try parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
    case 0x6E:
      try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
    case 0x2D, 0x30...0x39:
      try parseNumber()
    default:
      throw MCPClientSessionError.protocolViolation
    }
  }

  private mutating func parseObject(depth: Int) throws {
    try consume(0x7B)
    skipWhitespace()
    if peek() == 0x7D {
      index += 1
      return
    }
    var names = Set<String>()
    while true {
      guard
        peek() == 0x22,
        let name = try parseString(decodingValue: true),
        names.insert(name).inserted
      else {
        throw MCPClientSessionError.protocolViolation
      }
      skipWhitespace()
      try consume(0x3A)
      try parseValue(depth: depth + 1)
      skipWhitespace()
      if peek() == 0x7D {
        index += 1
        return
      }
      try consume(0x2C)
      skipWhitespace()
    }
  }

  private mutating func parseArray(depth: Int) throws {
    try consume(0x5B)
    skipWhitespace()
    if peek() == 0x5D {
      index += 1
      return
    }
    while true {
      try parseValue(depth: depth + 1)
      skipWhitespace()
      if peek() == 0x5D {
        index += 1
        return
      }
      try consume(0x2C)
      skipWhitespace()
    }
  }

  private mutating func parseString(decodingValue: Bool) throws -> String? {
    let start = index
    try consume(0x22)
    while let byte = peek() {
      index += 1
      switch byte {
      case 0x22:
        guard decodingValue else { return nil }
        do {
          return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
        } catch {
          throw MCPClientSessionError.protocolViolation
        }
      case 0x5C:
        guard let escape = peek() else {
          throw MCPClientSessionError.protocolViolation
        }
        index += 1
        switch escape {
        case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
          break
        case 0x75:
          for _ in 0..<4 {
            guard let digit = peek(), isHexDigit(digit) else {
              throw MCPClientSessionError.protocolViolation
            }
            index += 1
          }
        default:
          throw MCPClientSessionError.protocolViolation
        }
      case 0x00...0x1F:
        throw MCPClientSessionError.protocolViolation
      default:
        break
      }
    }
    throw MCPClientSessionError.protocolViolation
  }

  private mutating func parseNumber() throws {
    if peek() == 0x2D { index += 1 }
    guard let first = peek() else {
      throw MCPClientSessionError.protocolViolation
    }
    if first == 0x30 {
      index += 1
      if let next = peek(), (0x30...0x39).contains(next) {
        throw MCPClientSessionError.protocolViolation
      }
    } else if (0x31...0x39).contains(first) {
      index += 1
      while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
    } else {
      throw MCPClientSessionError.protocolViolation
    }
    if peek() == 0x2E {
      index += 1
      guard let digit = peek(), (0x30...0x39).contains(digit) else {
        throw MCPClientSessionError.protocolViolation
      }
      while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
    }
    if let exponent = peek(), exponent == 0x45 || exponent == 0x65 {
      index += 1
      if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
      guard let digit = peek(), (0x30...0x39).contains(digit) else {
        throw MCPClientSessionError.protocolViolation
      }
      while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
    }
  }

  private mutating func parseLiteral(_ literal: [UInt8]) throws {
    guard index <= bytes.count - literal.count else {
      throw MCPClientSessionError.protocolViolation
    }
    for expected in literal {
      try consume(expected)
    }
  }

  private mutating func consume(_ expected: UInt8) throws {
    guard peek() == expected else {
      throw MCPClientSessionError.protocolViolation
    }
    index += 1
  }

  private mutating func skipWhitespace() {
    while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
      index += 1
    }
  }

  private func peek() -> UInt8? {
    guard index < bytes.count else { return nil }
    return bytes[index]
  }

  private func isHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
      || (0x41...0x46).contains(byte)
      || (0x61...0x66).contains(byte)
  }
}
