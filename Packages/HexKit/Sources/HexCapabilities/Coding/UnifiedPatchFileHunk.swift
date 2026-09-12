struct UnifiedPatchFileHunk: Sendable {
  let oldStart: Int
  let oldCount: Int
  let newStart: Int
  let newCount: Int
  let lines: [String]
}
