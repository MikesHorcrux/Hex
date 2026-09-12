import Foundation

/// Deliberately small unified-diff dialect: UTF-8 text, exact hunks, a/ and b/ paths, /dev/null.
/// No fuzzy offsets, rename/mode/binary records, quoted paths, timestamps or implicit directories.
struct UnifiedPatch: Sendable {
  let files: [UnifiedPatchFile]

  init(_ text: String) throws {
    guard text.utf8.count <= 512 * 1_024, !text.contains("\0"), text.hasSuffix("\n") else {
      throw WorkspacePatchError.invalidPatch
    }
    var lines = text.components(separatedBy: "\n")
    lines.removeLast()
    var index = 0
    var result: [UnifiedPatchFile] = []
    var seen: Set<String> = []
    func path(_ line: String, prefix: String) throws -> String? {
      guard line.hasPrefix(prefix) else { throw WorkspacePatchError.invalidPatch }
      let value = String(line.dropFirst(prefix.count))
      if value == "/dev/null" { return nil }
      guard value.hasPrefix(prefix == "--- " ? "a/" : "b/"), !value.contains("\t"),
        !value.contains("\\")
      else {
        throw WorkspaceFileSystemError.invalidPath
      }
      let path = String(value.dropFirst(2))
      let parsed = try WorkspaceRelativePath(path)
      guard !parsed.components.isEmpty, !parsed.components.contains(".git") else {
        throw WorkspaceFileSystemError.invalidPath
      }
      return path
    }
    func range(_ value: Substring, prefix: Character) throws -> (Int, Int) {
      guard value.first == prefix else { throw WorkspacePatchError.invalidPatch }
      let fields = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
      guard (1...2).contains(fields.count), let start = Int(fields[0]), start >= 0,
        start <= 1_000_000,
        let count = fields.count == 2 ? Int(fields[1]) : 1, count >= 0, count <= 1_000_000,
        count == 0 || start > 0
      else { throw WorkspacePatchError.invalidPatch }
      return (start, count)
    }
    while index < lines.count {
      guard result.count < 32, index + 1 < lines.count else {
        throw WorkspacePatchError.invalidPatch
      }
      let old = try path(lines[index], prefix: "--- ")
      let new = try path(lines[index + 1], prefix: "+++ ")
      guard let name = new ?? old, old == nil || new == nil || old == new,
        seen.insert(name).inserted
      else {
        throw WorkspacePatchError.invalidPatch
      }
      index += 2
      var hunks: [UnifiedPatchFileHunk] = []
      while index < lines.count && lines[index].hasPrefix("@@ ") {
        guard hunks.count < 256 else { throw WorkspacePatchError.invalidPatch }
        let header = lines[index].split(separator: " ")
        guard header.count >= 4, header[0] == "@@", header[3] == "@@" else {
          throw WorkspacePatchError.invalidPatch
        }
        let a = try range(header[1], prefix: "-")
        let b = try range(header[2], prefix: "+")
        index += 1
        var body: [String] = []
        var oldCount = 0
        var newCount = 0
        while index < lines.count && (oldCount < a.1 || newCount < b.1) {
          let line = lines[index]
          guard let prefix = line.first, [" ", "-", "+"].contains(prefix) else {
            throw WorkspacePatchError.invalidPatch
          }
          if prefix != "+" { oldCount += 1 }
          if prefix != "-" { newCount += 1 }
          guard oldCount <= a.1, newCount <= b.1 else { throw WorkspacePatchError.invalidPatch }
          body.append(line)
          index += 1
        }
        guard oldCount == a.1, newCount == b.1 else { throw WorkspacePatchError.invalidPatch }
        hunks.append(.init(oldStart: a.0, oldCount: a.1, newStart: b.0, newCount: b.1, lines: body))
      }
      guard !hunks.isEmpty else { throw WorkspacePatchError.invalidPatch }
      result.append(.init(path: name, creates: old == nil, deletes: new == nil, hunks: hunks))
    }
    guard !result.isEmpty else { throw WorkspacePatchError.invalidPatch }
    files = result
  }

  func applying(_ file: UnifiedPatchFile, to source: String) throws -> String {
    // Missing final-newline input requires an explicit full-file write, avoiding ambiguous hunks.
    guard source.isEmpty || source.hasSuffix("\n") else { throw WorkspacePatchError.invalidPatch }
    var old = source.components(separatedBy: "\n")
    old.removeLast()
    var cursor = 0
    var output: [String] = []
    for hunk in file.hunks {
      let start = hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1
      guard start >= cursor, start <= old.count else {
        throw WorkspaceFileSystemError.revisionConflict
      }
      output += old[cursor..<start]
      cursor = start
      let newStart = hunk.newCount == 0 ? hunk.newStart : hunk.newStart - 1
      guard newStart == output.count else { throw WorkspacePatchError.invalidPatch }
      for line in hunk.lines {
        let text = String(line.dropFirst())
        if line.first != "+" {
          guard cursor < old.count, old[cursor] == text else {
            throw WorkspaceFileSystemError.revisionConflict
          }
          cursor += 1
        }
        if line.first != "-" { output.append(text) }
      }
    }
    output += old[cursor...]
    let content = output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
    guard content.utf8.count <= 512 * 1_024, !file.deletes || content.isEmpty else {
      throw WorkspaceFileSystemError.fileTooLarge
    }
    return content
  }
}
