import Foundation
import MachO
import Testing

@testable import HexIPC

@Suite("Executable build identity comes from the loaded Mach-O image")
struct GatewayExecutableIdentityTests {
  @Test
  func currentProcessMatchesItsUnreplacedExecutable() throws {
    let url = try #require(Bundle.main.executableURL)
    let running = try #require(GatewayExecutableIdentity.runningExecutableID)
    #expect(try GatewayExecutableIdentity.executableID(at: url) == running)
    #expect(GatewayExecutableIdentity.runningImageID(named: url.lastPathComponent) == running)
    #expect(GatewayExecutableIdentity.runningImageID(named: "Hex-nonexistent-image.dylib") == nil)
  }

  @Test
  func rejectsMalformedOrAmbiguousLoadCommands() {
    let valid = image()
    #expect(GatewayExecutableIdentity.parse(valid) != nil)
    #expect(GatewayExecutableIdentity.parse(Data(valid.dropLast())) == nil)
    #expect(GatewayExecutableIdentity.parse(Data()) == nil)
    var invalidSize = valid
    invalidSize.replaceSubrange(36..<40, with: word(7))
    #expect(GatewayExecutableIdentity.parse(invalidSize) == nil)
    var tooManyCommands = valid
    tooManyCommands.replaceSubrange(16..<20, with: word(UInt32.max))
    #expect(GatewayExecutableIdentity.parse(tooManyCommands) == nil)
    var duplicate = valid
    duplicate.replaceSubrange(16..<20, with: word(2))
    duplicate.replaceSubrange(20..<24, with: word(48))
    duplicate.append(valid.suffix(24))
    #expect(GatewayExecutableIdentity.parse(duplicate) == nil)
  }

  @Test
  func legacyHandshakeDoesNotInventAnExecutableIdentity() throws {
    let response = GatewayHandshakeResponse(
      sessionID: GatewaySessionID(), gatewayInstanceID: GatewayInstanceID(),
      selectedVersion: .current, activeRun: nil)
    let encoded = try JSONEncoder().encode(response)
    #expect(
      try JSONDecoder().decode(GatewayHandshakeResponse.self, from: encoded).executableID == nil)
  }

  private func image() -> Data {
    var data = Data()
    let words: [UInt32] = [UInt32(MH_MAGIC_64), 0, 0, 0, 1, 24, 0, 0, UInt32(LC_UUID), 24]
    for value in words {
      data.append(word(value))
    }
    data.append(contentsOf: (0..<16).map { UInt8($0) })
    return data
  }

  private func word(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
  }
}
