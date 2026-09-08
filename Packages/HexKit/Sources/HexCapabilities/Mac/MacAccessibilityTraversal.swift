/// Visits each subtree before its siblings so shallow application menus cannot exhaust the budget
/// before deeply nested window content. Paths retain the original Accessibility child indices.
enum MacAccessibilityTraversal {
  static func walk<Node>(
    root: Node, maximumDepth: Int, maximumElements: Int,
    children: (Node, String) throws -> [Node],
    visit: (Node, String, Int) throws -> Void
  ) throws -> Bool {
    var pending: [(element: Node, depth: Int, path: String)] = [(root, 0, "0")]
    var visited = 0
    var isTruncated = false
    while let node = pending.popLast() {
      guard visited < maximumElements else { return true }
      let descendants = try children(node.element, node.path)
      try visit(node.element, node.path, descendants.count)
      visited += 1
      if node.depth < maximumDepth {
        let capacity = max(maximumElements - visited - pending.count, 0)
        if descendants.count > capacity { isTruncated = true }
        for (index, child) in descendants.enumerated().prefix(capacity).reversed() {
          pending.append((child, node.depth + 1, "\(node.path).\(index)"))
        }
      } else if !descendants.isEmpty {
        isTruncated = true
      }
    }
    return isTruncated
  }
}
