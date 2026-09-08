import Foundation

/// Structural validation does not grant access. The reader must also match the stored manifest.
public enum ToolArtifactValidation {
  public static func validate(_ references: [ArtifactReference]) throws {
    guard references.count <= 256 else { throw ArtifactStoreError.invalidRequest }
    var seen: [UUID: ArtifactReference] = [:]
    for reference in references {
      guard reference.byteCount >= 0,
        !reference.mediaType.isEmpty, reference.mediaType.utf8.count <= 128,
        reference.mediaType.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
        reference.sha256.utf8.count == 64,
        reference.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        reference.toolCallID.map({ !$0.rawValue.isEmpty && $0.rawValue.utf8.count <= 512 }) ?? true
      else { throw ArtifactStoreError.invalidRequest }
      if let previous = seen[reference.id], previous != reference {
        throw ArtifactStoreError.invalidRequest
      }
      seen[reference.id] = reference
    }
  }
}
