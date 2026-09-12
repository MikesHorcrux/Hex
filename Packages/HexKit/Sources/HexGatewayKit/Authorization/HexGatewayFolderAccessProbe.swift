import Darwin
import Foundation
import HexIPC

/// Reads one entry (without retaining its name) in the actual configured directory. There is no
/// public macOS Full Disk Access status API; this deliberately says nothing about other folders.
public struct HexGatewayFolderAccessProbe: Sendable {
  private let directory: URL
  private let agentBundle: URL
  private let read: @Sendable (URL) -> GatewayFolderAccessMode

  public init(
    directory: URL, agentBundle: URL,
    read: @escaping @Sendable (URL) -> GatewayFolderAccessMode = Self.readDirectory
  ) {
    self.directory = directory
    self.agentBundle = agentBundle
    self.read = read
  }

  public func check() throws -> GatewayFolderAccessStatus {
    try Task.checkCancellation()
    _ = try GatewayFolderAccessStatus(
      directory: directory, agentBundle: agentBundle, access: .unavailable
    ).validated()
    return try GatewayFolderAccessStatus(
      directory: directory, agentBundle: agentBundle, access: read(directory)
    ).validated()
  }

  public static func readDirectory(_ directory: URL) -> GatewayFolderAccessMode {
    guard let stream = opendir(directory.path) else { return access(for: errno) }
    defer { closedir(stream) }
    errno = 0
    _ = readdir(stream)
    return access(for: errno)
  }

  private static func access(for code: Int32) -> GatewayFolderAccessMode {
    switch code {
    case 0: .readable
    case EACCES, EPERM: .denied
    default: .unavailable
    }
  }
}
