import Darwin
import HexCore
import HexProviders
import Testing

@testable import HexMLXProvider

@Suite("MLX model artifact")
struct MLXModelArtifactTests {
  @Test
  func capturesCurrentUserOwnershipAndSafePermissions() throws {
    var status = stat()
    status.st_mode = S_IFREG | mode_t(0o640)
    status.st_uid = geteuid()
    status.st_gid = getegid()
    status.st_nlink = 1
    status.st_size = 1

    let artifact = try MLXModelArtifact(
      name: "model.safetensors",
      fileDescriptor: -1,
      status: status
    )

    var foreignOwner = status
    foreignOwner.st_uid = status.st_uid == 0 ? 1 : 0
    #expect(!artifact.matches(foreignOwner))

    var changedGroup = status
    changedGroup.st_gid = status.st_gid == 0 ? 1 : 0
    #expect(!artifact.matches(changedGroup))

    var changedMode = status
    changedMode.st_mode = S_IFREG | mode_t(0o600)
    #expect(!artifact.matches(changedMode))
  }

  @Test
  func rejectsForeignOwnersAndGroupWritableModesAtCapture() {
    var status = stat()
    status.st_mode = S_IFREG | mode_t(0o640)
    status.st_uid = geteuid()
    status.st_gid = getegid()
    status.st_nlink = 1
    status.st_size = 1

    var foreignOwner = status
    foreignOwner.st_uid = status.st_uid == 0 ? 1 : 0
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifact(
        name: "model.safetensors",
        fileDescriptor: -1,
        status: foreignOwner
      )
    }

    var groupWritable = status
    groupWritable.st_mode = S_IFREG | mode_t(0o660)
    #expect(throws: MLXLocalInferenceProviderError.invalidModelConfiguration) {
      _ = try MLXModelArtifact(
        name: "model.safetensors",
        fileDescriptor: -1,
        status: groupWritable
      )
    }
  }
}
