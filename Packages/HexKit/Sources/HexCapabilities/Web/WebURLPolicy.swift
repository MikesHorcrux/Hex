import Darwin
import Foundation

enum WebURLPolicy {
  static func validatedURL(from value: String) throws -> URL {
    guard
      !value.isEmpty,
      value.utf8.count <= 8_192,
      !value.contains("\0"),
      let parsed = URL(string: value)
    else {
      throw WebToolError.invalidArguments
    }
    return try validatedURL(parsed)
  }

  static func validatedURL(_ value: URL) throws -> URL {
    guard
      value.scheme?.lowercased() == "https",
      value.user == nil,
      value.password == nil,
      value.port == nil || value.port == 443,
      let host = value.host?.lowercased(),
      !host.isEmpty,
      host == host.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
      host != "localhost",
      !host.hasSuffix(".localhost"),
      !host.hasSuffix(".local"),
      !host.hasSuffix(".internal"),
      !host.hasSuffix(".home"),
      !host.hasSuffix(".lan")
    else {
      throw WebToolError.urlNotAllowed
    }
    guard !isIPAddress(host) else {
      throw WebToolError.urlNotAllowed
    }
    var components = URLComponents(url: value, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    guard let normalized = components?.url else {
      throw WebToolError.urlNotAllowed
    }
    return normalized
  }

  private static func isIPAddress(_ host: String) -> Bool {
    var ipv4 = in_addr()
    var ipv6 = in6_addr()
    return host.withCString { pointer in
      inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
    }
  }
}
