import Darwin
import Foundation
import HexCore

enum FileArtifactInventory {
  static let maximumEntries = 65_536

  /// Count every blob, including incomplete/abandoned/crash leftovers. Nothing is silently evicted.
  /// Manifests are separately bounded to 4 KiB and the namespace has a fixed entry-count guard.
  static func payloadBytes(in directory: FileArtifactDirectory, reservingArtifacts: Int = 0) throws
    -> Int64
  {
    let descriptor = Darwin.openat(
      directory.descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ArtifactStoreError.unavailable }
    guard let stream = fdopendir(descriptor) else {
      Darwin.close(descriptor)
      throw ArtifactStoreError.unavailable
    }
    defer { closedir(stream) }
    var total: Int64 = 0
    var entries = 0
    var blobs = 0
    var manifests = 0
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw ArtifactStoreError.unavailable }
        guard manifests <= blobs else { throw ArtifactStoreError.corrupt }
        // Every pending/abandoned blob consumes a manifest slot too. Concurrent sessions therefore
        // cannot admit cheap empty blobs and only exceed namespace capacity when they finish.
        guard blobs <= maximumEntries / 2 - reservingArtifacts else {
          throw ArtifactStoreError.quotaExceeded
        }
        return total
      }
      let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(cString: $0)
        }
      }
      if name == "." || name == ".." || name == ".artifact-lock" { continue }
      entries += 1
      guard entries <= maximumEntries else { throw ArtifactStoreError.quotaExceeded }
      let suffix: String
      if name.hasSuffix(".blob") {
        suffix = ".blob"
      } else if name.hasSuffix(".json") {
        suffix = ".json"
      } else {
        throw ArtifactStoreError.corrupt
      }
      let rawID = String(name.dropLast(suffix.count))
      guard let id = UUID(uuidString: rawID), id.uuidString.lowercased() == rawID else {
        throw ArtifactStoreError.corrupt
      }
      let file = Darwin.openat(
        directory.descriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      guard file >= 0 else { throw ArtifactStoreError.corrupt }
      let status: stat
      do { status = try FileArtifactIO.status(file) } catch {
        Darwin.close(file)
        throw error
      }
      Darwin.close(file)
      if suffix == ".json" {
        manifests += 1
        guard status.st_size <= FileArtifactIO.maximumManifestBytes else {
          throw ArtifactStoreError.corrupt
        }
      } else {
        blobs += 1
        let (next, overflow) = total.addingReportingOverflow(Int64(status.st_size))
        guard !overflow else { throw ArtifactStoreError.quotaExceeded }
        total = next
      }
    }
  }
}
