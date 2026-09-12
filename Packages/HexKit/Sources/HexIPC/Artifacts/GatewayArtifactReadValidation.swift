import Foundation
import HexCore

enum GatewayArtifactReadValidation {
  static func request(_ request: GatewayArtifactReadRequest) throws {
    let reference = request.reference
    let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    guard reference.id != zero, reference.runID.rawValue != zero,
      reference.byteCount >= 0, request.offset >= 0, request.offset <= reference.byteCount,
      (1...65_536).contains(request.maximumBytes),
      !reference.mediaType.isEmpty, reference.mediaType.utf8.count <= 256,
      reference.mediaType.utf8.allSatisfy({ (32...126).contains($0) }),
      reference.sha256.utf8.count == 64,
      reference.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw malformed() }
    if let toolCallID = reference.toolCallID {
      guard !toolCallID.rawValue.isEmpty, toolCallID.rawValue.utf8.count <= 1_024,
        !toolCallID.rawValue.contains("\0")
      else { throw malformed() }
    }
  }

  static func response(_ response: GatewayArtifactReadResponse, request: GatewayArtifactReadRequest)
    throws
  {
    try self.request(request)
    guard response.reference == request.reference, response.offset == request.offset,
      response.data.count <= request.maximumBytes,
      Int64(response.data.count) <= request.reference.byteCount - request.offset,
      !response.data.isEmpty || request.offset == request.reference.byteCount
    else { throw malformed() }
    let end = request.offset + Int64(response.data.count)
    guard response.nextOffset == (end < request.reference.byteCount ? end : nil) else {
      throw malformed()
    }
  }

  static func failure(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let failure = error as? GatewayFailure { return failure }
    return GatewayFailure(
      code: .artifactUnavailable,
      message: "The preserved output could not be read safely. No command was repeated.")
  }

  private static func malformed() -> GatewayFailure {
    GatewayFailure(
      code: .malformedPayload,
      message: "The artifact identity, byte range or returned data does not match its manifest.")
  }
}
