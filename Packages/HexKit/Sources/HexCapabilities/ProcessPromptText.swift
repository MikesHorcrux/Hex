import Foundation

/// Projects process text into a representation safe to place in an authorization prompt or a
/// model-visible result. Ordinary Unicode remains readable; terminal controls, format characters,
/// and ambiguous separators become explicit escapes.
enum ProcessPromptText {
  static func renderArguments(
    _ arguments: [String],
    maximumBytes: Int
  ) -> (values: [String], truncated: Bool) {
    guard maximumBytes > 0 else {
      return ([], !arguments.isEmpty)
    }

    let perArgumentMaximum = min(maximumBytes, 4 * 1_024)
    var values: [String] = []
    values.reserveCapacity(arguments.count)
    var usedBytes = 0
    var truncated = false

    for argument in arguments {
      let complete = render(argument, quoted: true)
      var value = boundedPrefix(complete, maximumBytes: perArgumentMaximum)
      if value.utf8.count < complete.utf8.count {
        value += "…"
        truncated = true
      }
      let separatorBytes = values.isEmpty ? 0 : 1
      let requiredBytes = separatorBytes + value.utf8.count
      guard requiredBytes <= maximumBytes - usedBytes else {
        truncated = true
        break
      }
      values.append(value)
      usedBytes += requiredBytes
    }

    return (values, truncated)
  }

  static func sanitizedUTF8Output(_ data: Data) -> (text: String, sanitized: Bool)? {
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
      return nil
    }

    var sanitizedText = ""
    sanitizedText.reserveCapacity(text.utf8.count)
    var wasSanitized = false
    for scalar in text.unicodeScalars {
      if scalar.value == 0x5C {
        sanitizedText += "\\\\"
        wasSanitized = true
      } else if appendEscape(for: scalar, to: &sanitizedText) {
        wasSanitized = true
      } else {
        sanitizedText.unicodeScalars.append(scalar)
      }
    }
    return (sanitizedText, wasSanitized)
  }

  private static func render(_ value: String, quoted: Bool) -> String {
    var result = quoted ? "\"" : ""
    result.reserveCapacity(value.utf8.count + (quoted ? 2 : 0))
    for scalar in value.unicodeScalars {
      if scalar.value == 0x5C || scalar.value == 0x22 {
        result.append("\\")
        result.unicodeScalars.append(scalar)
      } else if appendEscape(for: scalar, to: &result) {
        continue
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    if quoted {
      result.append("\"")
    }
    return result
  }

  private static func appendEscape(
    for scalar: Unicode.Scalar,
    to result: inout String
  ) -> Bool {
    switch scalar.value {
    case 0x08:
      result += "\\b"
      return true
    case 0x09:
      result += "\\t"
      return true
    case 0x0A:
      result += "\\n"
      return true
    case 0x0C:
      result += "\\f"
      return true
    case 0x0D:
      result += "\\r"
      return true
    default:
      break
    }

    guard !WorkspacePathScalarPolicy.isPromptSafe(String(scalar)) else {
      return false
    }
    result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
    return true
  }

  private static func boundedPrefix(_ value: String, maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else {
      return value
    }

    var result = ""
    result.reserveCapacity(maximumBytes)
    var usedBytes = 0
    for scalar in value.unicodeScalars {
      let scalarBytes = String(scalar).utf8.count
      guard usedBytes + scalarBytes <= maximumBytes else {
        break
      }
      result.unicodeScalars.append(scalar)
      usedBytes += scalarBytes
    }
    return result
  }
}
