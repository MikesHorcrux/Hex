import Darwin
import Foundation

struct WorkspaceWriteTransaction {
  let directoryURL: URL
  let directoryDescriptor: Int32
  let candidateName: String
  let candidateDescriptor: Int32

  init(namespace: WorkspaceWriteTransactionNamespace) throws {
    directoryURL = namespace.directoryURL
    directoryDescriptor = namespace.directoryDescriptor
    var openedDescriptor: Int32 = -1
    var openedName = ""
    for _ in 0..<16 {
      let name = Self.uniqueName(prefix: "candidate")
      let descriptor = openat(
        directoryDescriptor,
        name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(0o600)
      )
      if descriptor >= 0 {
        openedDescriptor = descriptor
        openedName = name
        break
      }
      guard errno == EEXIST else {
        throw WorkspaceFileSystemError.outcomeUncertain
      }
    }
    guard openedDescriptor >= 0 else {
      throw WorkspaceFileSystemError.capacityExceeded
    }
    candidateName = openedName
    candidateDescriptor = openedDescriptor
  }

  func close() {
    Darwin.close(candidateDescriptor)
  }

  static func uniqueName(prefix: String) -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes.withUnsafeMutableBytes { buffer in
      arc4random_buf(buffer.baseAddress, buffer.count)
    }
    let alphabet = Array("0123456789abcdef".utf8)
    var suffix = [UInt8]()
    suffix.reserveCapacity(bytes.count * 2)
    for byte in bytes {
      suffix.append(alphabet[Int(byte >> 4)])
      suffix.append(alphabet[Int(byte & 0x0f)])
    }
    return "\(prefix)-\(String(decoding: suffix, as: UTF8.self))"
  }
}
