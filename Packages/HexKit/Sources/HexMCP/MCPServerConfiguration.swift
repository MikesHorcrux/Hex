import Foundation

public struct MCPServerConfiguration: Sendable {
  public let serverID: String
  public let executableURL: URL
  public let arguments: [String]
  public let workingDirectory: URL
  public let environment: [String: String]
  public let clientName: String
  public let clientVersion: String
  public let requestTimeoutMilliseconds: UInt64
  public let shutdownGraceMilliseconds: UInt64
  public let maximumMessageBytes: Int
  public let maximumStderrBytes: Int
  public let maximumToolPages: Int
  public let maximumTools: Int
  public let maximumContentItems: Int
  public let maximumArgumentsBytes: Int

  public init(
    serverID: String,
    executableURL: URL,
    arguments: [String],
    workingDirectory: URL,
    environment: [String: String],
    clientName: String = "Hex",
    clientVersion: String = "0.1.0",
    requestTimeoutMilliseconds: UInt64 = 30_000,
    shutdownGraceMilliseconds: UInt64 = 250,
    maximumMessageBytes: Int = 2 * 1_024 * 1_024,
    maximumStderrBytes: Int = 64 * 1_024,
    maximumToolPages: Int = 32,
    maximumTools: Int = 4_096,
    maximumContentItems: Int = 1_024,
    maximumArgumentsBytes: Int = 512 * 1_024
  ) throws {
    guard MCPToolCatalogBuilder.isValidServerID(serverID) else {
      throw MCPServerConfigurationError.invalidServerID
    }
    guard
      executableURL.isFileURL,
      executableURL.path.hasPrefix("/"),
      !executableURL.path.contains("\0"),
      executableURL.path.utf8.count <= 4_096
    else {
      throw MCPServerConfigurationError.invalidExecutable
    }
    guard
      workingDirectory.isFileURL,
      workingDirectory.path.hasPrefix("/"),
      !workingDirectory.path.contains("\0"),
      workingDirectory.path.utf8.count <= 4_096
    else {
      throw MCPServerConfigurationError.invalidWorkingDirectory
    }
    guard Self.validArguments(arguments) else {
      throw MCPServerConfigurationError.invalidArguments
    }
    guard Self.validEnvironment(environment) else {
      throw MCPServerConfigurationError.invalidEnvironment
    }
    guard
      Self.validIdentityPart(clientName),
      Self.validIdentityPart(clientVersion)
    else {
      throw MCPServerConfigurationError.invalidClientIdentity
    }
    guard
      (1...300_000).contains(requestTimeoutMilliseconds),
      (1...10_000).contains(shutdownGraceMilliseconds),
      (1_024...8 * 1_024 * 1_024).contains(maximumMessageBytes),
      (0...1 * 1_024 * 1_024).contains(maximumStderrBytes),
      (1...128).contains(maximumToolPages),
      (1...4_096).contains(maximumTools),
      (1...4_096).contains(maximumContentItems),
      (1_024...2 * 1_024 * 1_024).contains(maximumArgumentsBytes)
    else {
      throw MCPServerConfigurationError.invalidLimit
    }

    self.serverID = serverID
    self.executableURL = executableURL.standardizedFileURL
    self.arguments = arguments
    self.workingDirectory = workingDirectory.standardizedFileURL
    self.environment = environment
    self.clientName = clientName
    self.clientVersion = clientVersion
    self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    self.shutdownGraceMilliseconds = shutdownGraceMilliseconds
    self.maximumMessageBytes = maximumMessageBytes
    self.maximumStderrBytes = maximumStderrBytes
    self.maximumToolPages = maximumToolPages
    self.maximumTools = maximumTools
    self.maximumContentItems = maximumContentItems
    self.maximumArgumentsBytes = maximumArgumentsBytes
  }

  private static func validArguments(_ values: [String]) -> Bool {
    guard values.count <= 256 else { return false }
    var totalBytes = 0
    for value in values {
      guard !value.contains("\0"), value.utf8.count <= 64 * 1_024 else { return false }
      let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(value.utf8.count + 1)
      guard !overflowed, nextTotal <= 256 * 1_024 else { return false }
      totalBytes = nextTotal
    }
    return true
  }

  private static func validEnvironment(_ values: [String: String]) -> Bool {
    guard values.count <= 128 else { return false }
    var totalBytes = 0
    for (name, value) in values {
      guard
        validEnvironmentName(name),
        !value.contains("\0"),
        value.utf8.count <= 64 * 1_024
      else {
        return false
      }
      let (nextTotal, overflowed) = totalBytes.addingReportingOverflow(
        name.utf8.count + value.utf8.count + 2
      )
      guard !overflowed, nextTotal <= 256 * 1_024 else { return false }
      totalBytes = nextTotal
    }
    return true
  }

  private static func validEnvironmentName(_ value: String) -> Bool {
    guard
      let first = value.utf8.first,
      value.utf8.count <= 128,
      first == 95 || (65...90).contains(first) || (97...122).contains(first)
    else {
      return false
    }
    return value.utf8.dropFirst().allSatisfy { byte in
      byte == 95
        || (48...57).contains(byte)
        || (65...90).contains(byte)
        || (97...122).contains(byte)
    }
  }

  private static func validIdentityPart(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty
      && trimmed == value
      && value.utf8.count <= 128
      && !value.contains("\0")
  }
}
