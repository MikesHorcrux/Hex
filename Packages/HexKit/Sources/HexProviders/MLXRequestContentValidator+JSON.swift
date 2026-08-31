import HexCore

extension MLXRequestContentValidator {
  static func validateJSONObject(
    _ object: [String: JSONValue],
    maximumBytes: Int,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    validateJSONValue(
      .object(object),
      maximumBytes: maximumBytes,
      remainingBytes: &remainingBytes,
      remainingNodes: &remainingNodes
    )
  }

  static func validateJSONValue(
    _ root: JSONValue,
    maximumBytes: Int,
    remainingBytes: inout Int,
    remainingNodes: inout Int
  ) -> Bool {
    var localBytes = 0
    var values = [(value: root, depth: 0)]
    while let current = values.popLast() {
      let (candidateLocalBytes, overflowed) = localBytes.addingReportingOverflow(8)
      guard
        current.depth <= maximumJSONDepth,
        !overflowed,
        candidateLocalBytes <= maximumBytes,
        consumeNode(remainingNodes: &remainingNodes),
        consume(8, remaining: &remainingBytes)
      else {
        return false
      }
      localBytes = candidateLocalBytes
      switch current.value {
      case .null, .boolean, .integer:
        break
      case .number(let value):
        guard value.isFinite, Int64(exactly: value) == nil else {
          return false
        }
      case .string(let value):
        guard
          consumeJSONValueString(
            value,
            maximumBytes: maximumBytes,
            localBytes: &localBytes,
            remainingBytes: &remainingBytes
          )
        else {
          return false
        }
      case .array(let elements):
        guard elements.count <= remainingNodes else {
          return false
        }
        values.append(contentsOf: elements.map { ($0, current.depth + 1) })
      case .object(let members):
        guard members.count <= remainingNodes else {
          return false
        }
        for (key, value) in members {
          guard
            !key.contains("\0"),
            consumeJSONValueString(
              key,
              maximumBytes: maximumBytes,
              localBytes: &localBytes,
              remainingBytes: &remainingBytes
            )
          else {
            return false
          }
          values.append((value, current.depth + 1))
        }
      }
    }
    return localBytes <= maximumBytes
  }

  static func consumeJSONValueString(
    _ value: String,
    maximumBytes: Int,
    localBytes: inout Int,
    remainingBytes: inout Int
  ) -> Bool {
    guard let bytes = encodedStringUpperBound(value) else {
      return false
    }
    let (candidateLocalBytes, overflowed) = localBytes.addingReportingOverflow(bytes)
    guard
      !overflowed,
      candidateLocalBytes <= maximumBytes,
      consume(bytes, remaining: &remainingBytes)
    else {
      return false
    }
    localBytes = candidateLocalBytes
    return true
  }

  static func consumeString(
    _ value: String,
    remainingBytes: inout Int
  ) -> Bool {
    guard let bytes = encodedStringUpperBound(value) else {
      return false
    }
    return consume(bytes, remaining: &remainingBytes)
  }

  static func encodedStringUpperBound(_ value: String) -> Int? {
    var bytes = 2
    for scalar in value.unicodeScalars {
      let additionalBytes: Int
      switch scalar.value {
      case 0...31:
        additionalBytes = 6
      case 34, 47, 92:
        additionalBytes = 2
      case 0x2028, 0x2029:
        additionalBytes = 6
      default:
        additionalBytes = scalar.utf8.count
      }
      let (candidate, overflowed) = bytes.addingReportingOverflow(additionalBytes)
      guard !overflowed else {
        return nil
      }
      bytes = candidate
    }
    return bytes
  }

  static func consumeNode(remainingNodes: inout Int) -> Bool {
    consume(1, remaining: &remainingNodes)
  }

  static func consume(_ amount: Int, remaining: inout Int) -> Bool {
    guard amount >= 0, remaining >= amount else {
      return false
    }
    remaining -= amount
    return true
  }
}
