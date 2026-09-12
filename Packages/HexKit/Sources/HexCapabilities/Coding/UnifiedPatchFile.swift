struct UnifiedPatchFile: Sendable {
  struct Hunk: Sendable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let lines: [String]
  }
  let path: String
  let creates: Bool
  let deletes: Bool
  let hunks: [Hunk]
}
