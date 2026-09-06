import Foundation

/// Installs a remote MLX model into a caller-owned local directory.
public protocol MLXLocalModelInstalling: Sendable {
  func install(
    modelID: String,
    progress: @Sendable @escaping (Double) -> Void
  ) async throws -> URL
}
