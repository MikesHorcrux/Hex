import Foundation
import HexCore

struct OpenAIJSONValidator {
  static func measuredBytes(
    for root: JSONValue,
    maximumDepth: Int,
    maximumNodes: Int,
    maximumStringBytes: Int
  ) -> Int? {
    var stack: [(JSONValue, Int)] = [(root, 1)]
    var nodeCount = 0
    var measuredBytes = 0

    while let (value, depth) = stack.popLast() {
      guard depth <= maximumDepth, nodeCount < maximumNodes else {
        return nil
      }
      nodeCount += 1

      switch value {
      case .null:
        guard add(4, to: &measuredBytes, maximum: maximumStringBytes) else { return nil }
      case .boolean:
        guard add(5, to: &measuredBytes, maximum: maximumStringBytes) else { return nil }
      case .integer:
        guard add(24, to: &measuredBytes, maximum: maximumStringBytes) else { return nil }
      case .number(let number):
        guard number.isFinite, Int64(exactly: number) == nil else { return nil }
        guard add(32, to: &measuredBytes, maximum: maximumStringBytes) else { return nil }
      case .string(let string):
        let byteCount = string.utf8.count
        guard byteCount <= maximumStringBytes else { return nil }
        guard
          let encodedUpperBound = encodedStringUpperBound(string),
          add(encodedUpperBound, to: &measuredBytes, maximum: maximumStringBytes)
        else {
          return nil
        }
      case .array(let values):
        guard
          values.count <= maximumNodes - nodeCount,
          add(values.count + 2, to: &measuredBytes, maximum: maximumStringBytes)
        else {
          return nil
        }
        for child in values.reversed() {
          stack.append((child, depth + 1))
        }
      case .object(let values):
        guard values.count <= maximumNodes - nodeCount else { return nil }
        guard add(values.count + 2, to: &measuredBytes, maximum: maximumStringBytes) else {
          return nil
        }
        for (key, child) in values {
          let byteCount = key.utf8.count
          guard byteCount <= maximumStringBytes else { return nil }
          guard let encodedUpperBound = encodedStringUpperBound(key) else { return nil }
          let (keyAndColonUpperBound, keyOverflowed) = encodedUpperBound.addingReportingOverflow(1)
          guard
            !keyOverflowed,
            add(keyAndColonUpperBound, to: &measuredBytes, maximum: maximumStringBytes)
          else {
            return nil
          }
          stack.append((child, depth + 1))
        }
      }
    }

    return measuredBytes
  }

  private static func add(_ amount: Int, to total: inout Int, maximum: Int) -> Bool {
    let (newTotal, overflowed) = total.addingReportingOverflow(amount)
    guard !overflowed, newTotal <= maximum else {
      return false
    }
    total = newTotal
    return true
  }

  private static func encodedStringUpperBound(_ value: String) -> Int? {
    var byteCount = 2
    for scalar in value.unicodeScalars {
      let scalarBytes: Int
      switch scalar.value {
      case 0...0x1F:
        scalarBytes = 6
      case 0x22, 0x5C:
        scalarBytes = 2
      case 0...0x7F:
        scalarBytes = 1
      case 0...0xFFFF:
        scalarBytes = 6
      default:
        scalarBytes = 12
      }
      let (newCount, overflowed) = byteCount.addingReportingOverflow(scalarBytes)
      guard !overflowed else { return nil }
      byteCount = newCount
    }
    return byteCount
  }
}
