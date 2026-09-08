enum MCPExposedToolName {
  static let maximumBytes = 64

  static func make(serverID: String, remoteName: String) -> String {
    let rawValue = "mcp_\(serverID.utf8.count)_\(serverID)_\(remoteName)"
    let rawBytes = Array(rawValue.utf8)
    let normalizedBytes = rawBytes.map { byte in
      isProviderPortable(byte) ? byte : UInt8(ascii: "_")
    }

    guard rawBytes == normalizedBytes, normalizedBytes.count <= maximumBytes else {
      let digest = hexadecimalDigest(for: rawBytes)
      let suffix = Array("_\(digest)".utf8)
      let prefix = normalizedBytes.prefix(maximumBytes - suffix.count)
      return String(decoding: prefix + suffix, as: UTF8.self)
    }
    return String(decoding: normalizedBytes, as: UTF8.self)
  }

  private static func isProviderPortable(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
      || (0x41...0x5A).contains(byte)
      || (0x61...0x7A).contains(byte)
      || byte == 0x5F
      || byte == 0x2D
  }

  private static func hexadecimalDigest(for bytes: [UInt8]) -> String {
    var digest: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
      digest ^= UInt64(byte)
      digest &*= 1_099_511_628_211
    }
    let value = String(digest, radix: 16, uppercase: false)
    return String(repeating: "0", count: 16 - value.count) + value
  }
}
