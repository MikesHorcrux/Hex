import Darwin
import Foundation

struct MCPMachOImage: Sendable {
  struct Dependency: Sendable, Equatable {
    let path: String
    let isRequired: Bool
  }

  let dependencies: [Dependency]
  let runpaths: [String]

  private static let maximumArchitectureCount = 64
  private static let maximumLoadCommandCount = 4_096
  private static let maximumLoadCommandBytes = 16 * 1_024 * 1_024
  private static let maximumPathBytes = 4_096
  private static let maximumPathCount = 4_096
  static let maximumRunpathCount = 1_024
  static let maximumRunpathBytes = 1 * 1_024 * 1_024
  static let maximumClosureRunpathCount = 8 * maximumRunpathCount
  static let maximumClosureRunpathBytes = 8 * maximumRunpathBytes

  static func read(from descriptor: Int32, fileSize: off_t) throws -> MCPMachOImage? {
    guard fileSize >= 4 else { return nil }
    let magic = try readBytes(from: descriptor, offset: 0, count: 4)
    if let format = thinFormat(magic) {
      return try readThinImage(
        from: descriptor,
        sliceOffset: 0,
        sliceSize: fileSize,
        format: format
      )
    }
    guard let fatFormat = fatFormat(magic) else { return nil }
    let header = try readBytes(from: descriptor, offset: 0, count: 8)
    guard let architectureCount = readUInt32(header, offset: 4, order: fatFormat.order),
      architectureCount > 0,
      architectureCount <= maximumArchitectureCount
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let entrySize = fatFormat.uses64BitOffsets ? 32 : 20
    let tableByteCount = Int(architectureCount) * entrySize
    guard tableByteCount <= maximumLoadCommandBytes,
      off_t(8 + tableByteCount) <= fileSize
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let table = try readBytes(from: descriptor, offset: 8, count: tableByteCount)
    var dependencies: [Dependency] = []
    var dependencyIndexes: [String: Int] = [:]
    var runpaths: [String] = []
    var runpathSet = Set<String>()
    var runpathBytes = 0
    for index in 0..<Int(architectureCount) {
      let entryOffset = index * entrySize
      let sliceOffset: UInt64?
      let sliceSize: UInt64?
      if fatFormat.uses64BitOffsets {
        sliceOffset = readUInt64(table, offset: entryOffset + 8, order: fatFormat.order)
        sliceSize = readUInt64(table, offset: entryOffset + 16, order: fatFormat.order)
      } else {
        sliceOffset = readUInt32(table, offset: entryOffset + 8, order: fatFormat.order)
          .map(UInt64.init)
        sliceSize = readUInt32(table, offset: entryOffset + 12, order: fatFormat.order)
          .map(UInt64.init)
      }
      guard let sliceOffset, let sliceSize,
        sliceSize >= 4,
        sliceOffset <= UInt64(fileSize),
        sliceSize <= UInt64(fileSize) - sliceOffset,
        sliceOffset <= UInt64(off_t.max),
        sliceSize <= UInt64(off_t.max)
      else {
        throw MCPClientSessionError.connectionClosed
      }
      let sliceMagic = try readBytes(
        from: descriptor,
        offset: off_t(sliceOffset),
        count: 4
      )
      guard let format = thinFormat(sliceMagic) else {
        throw MCPClientSessionError.connectionClosed
      }
      let image = try readThinImage(
        from: descriptor,
        sliceOffset: off_t(sliceOffset),
        sliceSize: off_t(sliceSize),
        format: format
      )
      appendUniqueDependencies(
        image.dependencies,
        to: &dependencies,
        indexes: &dependencyIndexes
      )
      try appendUniqueRunpaths(
        image.runpaths,
        to: &runpaths,
        set: &runpathSet,
        byteCount: &runpathBytes
      )
      guard dependencies.count <= maximumPathCount,
        runpaths.count <= maximumRunpathCount,
        runpathBytes <= maximumRunpathBytes
      else {
        throw MCPClientSessionError.connectionClosed
      }
    }
    return MCPMachOImage(dependencies: dependencies, runpaths: runpaths)
  }

  private static func readThinImage(
    from descriptor: Int32,
    sliceOffset: off_t,
    sliceSize: off_t,
    format: ThinFormat
  ) throws -> MCPMachOImage {
    let headerSize = format.uses64BitHeader ? 32 : 28
    guard sliceSize >= headerSize else {
      throw MCPClientSessionError.connectionClosed
    }
    let header = try readBytes(from: descriptor, offset: sliceOffset, count: headerSize)
    guard let commandCount = readUInt32(header, offset: 16, order: format.order),
      let commandBytes = readUInt32(header, offset: 20, order: format.order),
      commandCount <= maximumLoadCommandCount,
      commandBytes <= maximumLoadCommandBytes,
      off_t(headerSize) + off_t(commandBytes) <= sliceSize
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let commands = try readBytes(
      from: descriptor,
      offset: sliceOffset + off_t(headerSize),
      count: Int(commandBytes)
    )
    var dependencies: [Dependency] = []
    var dependencyIndexes: [String: Int] = [:]
    var runpaths: [String] = []
    var runpathSet = Set<String>()
    var runpathBytes = 0
    var commandOffset = 0
    for _ in 0..<Int(commandCount) {
      guard let command = readUInt32(commands, offset: commandOffset, order: format.order),
        let commandSize = readUInt32(
          commands,
          offset: commandOffset + 4,
          order: format.order
        ),
        commandSize >= 8,
        commandSize % 4 == 0,
        Int(commandSize) <= commands.count - commandOffset
      else {
        throw MCPClientSessionError.connectionClosed
      }
      if dependencyCommands.contains(command) {
        let path = try readLoadCommandPath(
          commands,
          commandOffset: commandOffset,
          commandSize: Int(commandSize),
          order: format.order,
          minimumOffset: 24
        )
        appendUniqueDependencies(
          [Dependency(path: path, isRequired: requiredDependencyCommands.contains(command))],
          to: &dependencies,
          indexes: &dependencyIndexes
        )
      } else if command == 0x8000_001C {
        let path = try readLoadCommandPath(
          commands,
          commandOffset: commandOffset,
          commandSize: Int(commandSize),
          order: format.order,
          minimumOffset: 12
        )
        try appendUniqueRunpaths(
          [path],
          to: &runpaths,
          set: &runpathSet,
          byteCount: &runpathBytes
        )
      }
      commandOffset += Int(commandSize)
    }
    guard commandOffset == commands.count,
      dependencies.count <= maximumPathCount,
      runpaths.count <= maximumRunpathCount,
      runpathBytes <= maximumRunpathBytes
    else {
      throw MCPClientSessionError.connectionClosed
    }
    return MCPMachOImage(dependencies: dependencies, runpaths: runpaths)
  }

  private static func readLoadCommandPath(
    _ commands: Data,
    commandOffset: Int,
    commandSize: Int,
    order: ByteOrder,
    minimumOffset: Int
  ) throws -> String {
    guard
      let pathOffset = readUInt32(
        commands,
        offset: commandOffset + 8,
        order: order
      ),
      pathOffset >= minimumOffset,
      Int(pathOffset) < commandSize
    else {
      throw MCPClientSessionError.connectionClosed
    }
    let start = commandOffset + Int(pathOffset)
    let end = commandOffset + commandSize
    let bytes = commands[start..<end].prefix { $0 != 0 }
    guard !bytes.isEmpty,
      bytes.count <= maximumPathBytes,
      bytes.count < end - start,
      let path = String(bytes: bytes, encoding: .utf8),
      !path.contains("\0")
    else {
      throw MCPClientSessionError.connectionClosed
    }
    return path
  }

  private static func readBytes(
    from descriptor: Int32,
    offset: off_t,
    count: Int
  ) throws -> Data {
    guard offset >= 0, count >= 0 else {
      throw MCPClientSessionError.connectionClosed
    }
    var bytes = [UInt8](repeating: 0, count: count)
    var completed = 0
    while completed < count {
      let readCount = bytes.withUnsafeMutableBytes { buffer in
        pread(
          descriptor,
          buffer.baseAddress?.advanced(by: completed),
          count - completed,
          offset + off_t(completed)
        )
      }
      if readCount < 0, errno == EINTR { continue }
      guard readCount > 0 else {
        throw MCPClientSessionError.connectionClosed
      }
      completed += readCount
    }
    return Data(bytes)
  }

  private static func thinFormat(_ magic: Data) -> ThinFormat? {
    switch Array(magic) {
    case [0xCE, 0xFA, 0xED, 0xFE]:
      ThinFormat(order: .little, uses64BitHeader: false)
    case [0xCF, 0xFA, 0xED, 0xFE]:
      ThinFormat(order: .little, uses64BitHeader: true)
    case [0xFE, 0xED, 0xFA, 0xCE]:
      ThinFormat(order: .big, uses64BitHeader: false)
    case [0xFE, 0xED, 0xFA, 0xCF]:
      ThinFormat(order: .big, uses64BitHeader: true)
    default:
      nil
    }
  }

  private static func fatFormat(_ magic: Data) -> FatFormat? {
    switch Array(magic) {
    case [0xCA, 0xFE, 0xBA, 0xBE]:
      FatFormat(order: .big, uses64BitOffsets: false)
    case [0xBE, 0xBA, 0xFE, 0xCA]:
      FatFormat(order: .little, uses64BitOffsets: false)
    case [0xCA, 0xFE, 0xBA, 0xBF]:
      FatFormat(order: .big, uses64BitOffsets: true)
    case [0xBF, 0xBA, 0xFE, 0xCA]:
      FatFormat(order: .little, uses64BitOffsets: true)
    default:
      nil
    }
  }

  private static func readUInt32(
    _ data: Data,
    offset: Int,
    order: ByteOrder
  ) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    let bytes = data[offset..<(offset + 4)]
    return order == .little
      ? bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
      : bytes.reduce(0) { ($0 << 8) | UInt32($1) }
  }

  private static func readUInt64(
    _ data: Data,
    offset: Int,
    order: ByteOrder
  ) -> UInt64? {
    guard offset >= 0, offset <= data.count - 8 else { return nil }
    let bytes = data[offset..<(offset + 8)]
    return order == .little
      ? bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
      : bytes.reduce(0) { ($0 << 8) | UInt64($1) }
  }

  private static func appendUniqueRunpaths(
    _ values: [String],
    to destination: inout [String],
    set: inout Set<String>,
    byteCount: inout Int
  ) throws {
    for value in values where set.insert(value).inserted {
      guard destination.count < maximumRunpathCount else {
        throw MCPClientSessionError.connectionClosed
      }
      let (nextByteCount, overflowed) = byteCount.addingReportingOverflow(value.utf8.count)
      guard !overflowed, nextByteCount <= maximumRunpathBytes else {
        throw MCPClientSessionError.connectionClosed
      }
      destination.append(value)
      byteCount = nextByteCount
    }
  }

  private static func appendUniqueDependencies(
    _ values: [Dependency],
    to destination: inout [Dependency],
    indexes: inout [String: Int]
  ) {
    for value in values {
      if let index = indexes[value.path] {
        if value.isRequired, !destination[index].isRequired {
          destination[index] = value
        }
      } else {
        indexes[value.path] = destination.count
        destination.append(value)
      }
    }
  }

  private static let dependencyCommands: Set<UInt32> = [
    0x0000_000C,
    0x8000_0018,
    0x8000_001F,
    0x0000_0020,
    0x8000_0023,
  ]

  private static let requiredDependencyCommands: Set<UInt32> = [
    0x0000_000C,
    0x8000_001F,
    0x8000_0023,
  ]

  private enum ByteOrder: Sendable {
    case little
    case big
  }

  private struct ThinFormat: Sendable {
    let order: ByteOrder
    let uses64BitHeader: Bool
  }

  private struct FatFormat: Sendable {
    let order: ByteOrder
    let uses64BitOffsets: Bool
  }
}
