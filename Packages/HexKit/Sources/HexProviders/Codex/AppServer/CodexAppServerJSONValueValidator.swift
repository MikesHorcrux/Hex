import HexCore

enum CodexAppServerJSONValueValidator {
  static func isValid(
    _ root: JSONValue,
    maximumDepth: Int = 64,
    maximumNodes: Int = 100_000,
    maximumStringBytes: Int,
    maximumEstimatedBytes: Int
  ) -> Bool {
    var stack: [(JSONValue, Int)] = [(root, 1)]
    var nodeCount = 0
    var estimatedBytes = 0

    while let (value, depth) = stack.popLast() {
      guard depth <= maximumDepth, nodeCount < maximumNodes else { return false }
      nodeCount += 1
      switch value {
      case .null:
        guard add(4, to: &estimatedBytes, maximum: maximumEstimatedBytes) else { return false }
      case .boolean:
        guard add(5, to: &estimatedBytes, maximum: maximumEstimatedBytes) else { return false }
      case .integer:
        guard add(24, to: &estimatedBytes, maximum: maximumEstimatedBytes) else { return false }
      case .number(let number):
        guard number.isFinite, Int64(exactly: number) == nil else { return false }
        guard add(32, to: &estimatedBytes, maximum: maximumEstimatedBytes) else { return false }
      case .string(let string):
        guard string.utf8.count <= maximumStringBytes,
          let upperBound = encodedStringUpperBound(string),
          add(upperBound, to: &estimatedBytes, maximum: maximumEstimatedBytes)
        else {
          return false
        }
      case .array(let values):
        guard values.count <= maximumNodes - nodeCount,
          add(values.count + 2, to: &estimatedBytes, maximum: maximumEstimatedBytes)
        else {
          return false
        }
        for value in values.reversed() {
          stack.append((value, depth + 1))
        }
      case .object(let values):
        guard values.count <= maximumNodes - nodeCount,
          add(values.count + 2, to: &estimatedBytes, maximum: maximumEstimatedBytes)
        else {
          return false
        }
        for (key, child) in values {
          guard key.utf8.count <= maximumStringBytes,
            let keyBound = encodedStringUpperBound(key),
            add(keyBound + 1, to: &estimatedBytes, maximum: maximumEstimatedBytes)
          else {
            return false
          }
          stack.append((child, depth + 1))
        }
      }
    }
    return true
  }

  private static func add(_ amount: Int, to total: inout Int, maximum: Int) -> Bool {
    let (candidate, overflowed) = total.addingReportingOverflow(amount)
    guard !overflowed, candidate <= maximum else { return false }
    total = candidate
    return true
  }

  private static func encodedStringUpperBound(_ value: String) -> Int? {
    var count = 2
    for scalar in value.unicodeScalars {
      let increment: Int
      switch scalar.value {
      case 0...0x1F:
        increment = 6
      case 0x22, 0x5C:
        increment = 2
      case 0...0x7F:
        increment = 1
      case 0...0xFFFF:
        increment = 6
      default:
        increment = 12
      }
      let (candidate, overflowed) = count.addingReportingOverflow(increment)
      guard !overflowed else { return nil }
      count = candidate
    }
    return count
  }
}
