import Darwin
import Foundation

public actor SystemWebAddressValidator: WebAddressValidating {
  public init() {}

  public func validate(_ url: URL) async throws {
    let validated = try WebURLPolicy.validatedURL(url)
    guard let host = validated.host else {
      throw WebToolError.urlNotAllowed
    }
    let isPublic = try await Task.detached(priority: .utility) {
      try Self.resolvesOnlyToPublicAddresses(host)
    }.value
    guard isPublic else {
      throw WebToolError.privateAddressRejected
    }
  }

  private nonisolated static func resolvesOnlyToPublicAddresses(
    _ host: String
  ) throws -> Bool {
    var hints = addrinfo()
    hints.ai_flags = AI_ADDRCONFIG
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
      throw WebToolError.hostResolutionFailed
    }
    defer { freeaddrinfo(first) }

    var foundAddress = false
    var current: UnsafeMutablePointer<addrinfo>? = first
    while let pointer = current {
      let info = pointer.pointee
      guard let address = info.ai_addr else {
        current = info.ai_next
        continue
      }
      switch info.ai_family {
      case AF_INET:
        let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
          pointer -> [UInt8] in
          var raw = pointer.pointee.sin_addr
          return withUnsafeBytes(of: &raw) { Array($0) }
        }
        foundAddress = true
        guard isPublicIPv4(bytes) else { return false }

      case AF_INET6:
        let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          pointer -> [UInt8] in
          var raw = pointer.pointee.sin6_addr
          return withUnsafeBytes(of: &raw) { Array($0) }
        }
        foundAddress = true
        guard isPublicIPv6(bytes) else { return false }

      default:
        break
      }
      current = info.ai_next
    }
    return foundAddress
  }

  private nonisolated static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 4 else { return false }
    let a = bytes[0]
    let b = bytes[1]
    let c = bytes[2]
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100, (64...127).contains(b) { return false }
    if a == 169, b == 254 { return false }
    if a == 172, (16...31).contains(b) { return false }
    if a == 192, b == 168 { return false }
    if a == 198, b == 18 || b == 19 { return false }
    if a == 192, b == 0, c == 0 || c == 2 { return false }
    if a == 198, b == 51, c == 100 { return false }
    if a == 203, b == 0, c == 113 { return false }
    return true
  }

  private nonisolated static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    let isIPv4Mapped =
      bytes.prefix(10).allSatisfy({ $0 == 0 })
      && bytes[10] == 0xFF && bytes[11] == 0xFF
    let isIPv4Compatible = bytes.prefix(12).allSatisfy({ $0 == 0 })
    if isIPv4Mapped || isIPv4Compatible {
      return isPublicIPv4(Array(bytes.suffix(4)))
    }

    // Public web destinations should resolve to global unicast space. This deliberately rejects
    // local, multicast, translation, and currently reserved ranges instead of guessing whether a
    // non-global address might be safe on this particular machine.
    guard bytes[0] & 0xE0 == 0x20 else { return false }
    if bytes[0] == 0x20, bytes[1] == 0x01 {
      if bytes[2] <= 0x01 { return false }  // IETF special-purpose 2001::/23.
      if bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }  // Documentation.
    }
    if bytes[0] == 0x20, bytes[1] == 0x02 { return false }  // Deprecated 6to4.
    if bytes[0] == 0x3F, bytes[1] == 0xFF, bytes[2] & 0xF0 == 0 {
      return false  // Documentation prefix 3fff::/20.
    }
    return true
  }
}
