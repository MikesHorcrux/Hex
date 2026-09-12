import Foundation

enum MacTargetValidator {
  static func validateBundleIdentifier(_ value: String) throws -> String {
    guard
      !value.isEmpty,
      value.utf8.count <= 255,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue.map { $0 < 32 } == true }
      ),
      value.contains("."),
      value.utf8.allSatisfy({ byte in
        (48...57).contains(byte)
          || (65...90).contains(byte)
          || (97...122).contains(byte)
          || byte == 45
          || byte == 46
      })
    else {
      throw MacToolError.invalidArguments
    }
    return value
  }

  static func validatePromptText(
    _ value: String?,
    maximumBytes: Int
  ) throws -> String? {
    guard let value else {
      return nil
    }
    guard
      !value.isEmpty,
      value.utf8.count <= maximumBytes,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw MacToolError.invalidArguments
    }
    return value
  }

  static func validateElementPath(_ value: String?) throws -> String? {
    guard let value else {
      return nil
    }
    guard value.utf8.count <= 512 else {
      throw MacToolError.invalidArguments
    }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard
      !parts.isEmpty,
      parts.count <= 32,
      parts.allSatisfy({ part in
        !part.isEmpty && part.count <= 6 && part.allSatisfy(\.isNumber)
      })
    else {
      throw MacToolError.invalidArguments
    }
    return value
  }
}
