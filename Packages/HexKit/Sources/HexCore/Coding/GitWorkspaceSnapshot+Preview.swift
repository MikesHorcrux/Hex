import Foundation

extension GitWorkspaceSnapshot {
  public var boundedPreview: Self {
    let paths = untracked.keys.sorted().prefix(30)
    let selected = Dictionary(
      uniqueKeysWithValues: paths.compactMap { path in untracked[path].map { (path, $0) } })
    return Self(
      repository: repository, head: head,
      status: Data(status.prefix(8_192)),
      stagedDiff: String(decoding: Data(stagedDiff.utf8).prefix(32_768), as: UTF8.self),
      unstagedDiff: String(decoding: Data(unstagedDiff.utf8).prefix(32_768), as: UTF8.self),
      untracked: selected, capturedAt: capturedAt,
      previewTruncated: status.count > 8_192 || stagedDiff.utf8.count > 32_768
        || unstagedDiff.utf8.count > 32_768 || selected.count != untracked.count)
  }
}
