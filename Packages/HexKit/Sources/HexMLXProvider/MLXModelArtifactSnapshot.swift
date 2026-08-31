import Foundation

actor MLXModelArtifactSnapshot {
  nonisolated let directory: URL

  init(directory: URL) {
    self.directory = directory
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }
}
