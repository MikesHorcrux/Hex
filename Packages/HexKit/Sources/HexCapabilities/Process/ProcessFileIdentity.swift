import Darwin
import Foundation

public struct ProcessFileIdentity: Codable, Equatable, Sendable {
  public let device: UInt64
  public let inode: UInt64
  public let mode: UInt64
  public let size: Int64
  public let modifiedSeconds: Int64
  public let modifiedNanoseconds: Int64
  public let changedSeconds: Int64
  public let changedNanoseconds: Int64

  init(
    device: UInt64,
    inode: UInt64,
    mode: UInt64,
    size: Int64,
    modifiedSeconds: Int64,
    modifiedNanoseconds: Int64,
    changedSeconds: Int64,
    changedNanoseconds: Int64
  ) {
    self.device = device
    self.inode = inode
    self.mode = mode
    self.size = size
    self.modifiedSeconds = modifiedSeconds
    self.modifiedNanoseconds = modifiedNanoseconds
    self.changedSeconds = changedSeconds
    self.changedNanoseconds = changedNanoseconds
  }

  var canonicalValues: [String] {
    [
      String(device),
      String(inode),
      String(mode),
      String(size),
      String(modifiedSeconds),
      String(modifiedNanoseconds),
      String(changedSeconds),
      String(changedNanoseconds),
    ]
  }

  init(status: stat) {
    self.init(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      mode: UInt64(status.st_mode),
      size: Int64(status.st_size),
      modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
      changedSeconds: Int64(status.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
    )
  }
}
