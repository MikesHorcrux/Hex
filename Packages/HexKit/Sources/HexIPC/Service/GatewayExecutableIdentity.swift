import Foundation
import MachO

/// Mach-O build UUIDs distinguish rebuilt helpers that still speak the same wire protocol.
/// This is build-coherence evidence, not a replacement for XPC code-signing admission.
public enum GatewayExecutableIdentity {
  private static let maximumCommandBytes = 1_048_576

  public static var runningExecutableID: UUID? {
    loadedImageID(at: 0)
  }

  /// Xcode may place app code in a debug dylib behind an unchanged launcher executable. Report
  /// that loaded code image separately, without reading a newer replacement from the bundle path.
  public static func runningImageID(named name: String) -> UUID? {
    for index in 0..<_dyld_image_count() {
      guard let path = _dyld_get_image_name(index),
        URL(fileURLWithPath: String(cString: path)).lastPathComponent == name
      else { continue }
      return loadedImageID(at: index)
    }
    return nil
  }

  private static func loadedImageID(at index: UInt32) -> UUID? {
    // dyld owns this immutable loaded main-image header for the process lifetime. Read the loaded
    // image, not its pathname: a rebuild may have replaced the executable file while it is running.
    guard let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64,
      header.pointee.sizeofcmds <= maximumCommandBytes
    else { return nil }
    return parse(
      Data(
        bytes: UnsafeRawPointer(header),
        count: MemoryLayout<mach_header_64>.size + Int(header.pointee.sizeofcmds)))
  }

  public static func executableID(at url: URL) throws -> UUID? {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let headerSize = MemoryLayout<mach_header_64>.size
    guard let header = try file.read(upToCount: headerSize), header.count == headerSize,
      word(header, at: 0) == MH_MAGIC_64,
      let commandBytes = word(header, at: 20), commandBytes <= maximumCommandBytes,
      let commands = try file.read(upToCount: Int(commandBytes)), commands.count == commandBytes
    else { return nil }
    return parse(header + commands)
  }

  static func parse(_ data: Data) -> UUID? {
    let headerSize = MemoryLayout<mach_header_64>.size
    guard data.count >= headerSize, word(data, at: 0) == MH_MAGIC_64,
      let commandCount = word(data, at: 16), let commandBytes = word(data, at: 20),
      commandBytes <= maximumCommandBytes, commandCount <= commandBytes / 8,
      data.count == headerSize + Int(commandBytes)
    else { return nil }
    var offset = headerSize
    var identifier: UUID?
    for _ in 0..<commandCount {
      guard let command = word(data, at: offset), let size = word(data, at: offset + 4),
        size >= 8, Int(size) <= data.count - offset
      else { return nil }
      if command == LC_UUID {
        guard size == MemoryLayout<uuid_command>.size, identifier == nil else { return nil }
        let bytes = Array(data[(offset + 8)..<(offset + 24)])
        identifier = UUID(
          uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
          ))
      }
      offset += Int(size)
    }
    return offset == data.count ? identifier : nil
  }

  private static func word(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return data.withUnsafeBytes { bytes in
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }
}
