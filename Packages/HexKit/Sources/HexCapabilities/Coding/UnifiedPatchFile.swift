struct UnifiedPatchFile: Sendable {
  let path: String
  let creates: Bool
  let deletes: Bool
  let hunks: [UnifiedPatchFileHunk]
}
