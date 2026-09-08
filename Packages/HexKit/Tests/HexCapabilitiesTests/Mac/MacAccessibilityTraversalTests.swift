import Testing

@testable import HexCapabilities

@Suite("Bounded native Accessibility traversal")
struct MacAccessibilityTraversalTests {
  @Test
  func windowContentPrecedesLargeShallowMenusWithoutChangingPaths() throws {
    var paths: [String: String] = [:]
    let truncated = try MacAccessibilityTraversal.walk(
      root: "application", maximumDepth: 12, maximumElements: 512,
      children: { node, _ in
        switch node {
        case "application": ["window", "menu"]
        case "window": ["split"]
        case "split": ["scroll"]
        case "scroll": ["web"]
        case "web": ["movie", "play"]
        case "menu": (0..<600).map { "menu\($0)" }
        default: []
        }
      },
      visit: { node, path, _ in paths[node] = path })
    #expect(truncated)
    #expect(paths.count == 512)
    #expect(paths["play"] == "0.0.0.0.0.1")
    #expect(paths["menu0"] == "0.1.0")
  }

  @Test
  func depthLimitReportsTruncationWithoutReadingDeeperNodes() throws {
    var reads: [Int] = []
    var visits: [Int] = []
    let truncated = try MacAccessibilityTraversal.walk(
      root: 0, maximumDepth: 2, maximumElements: 512,
      children: { node, _ in
        reads.append(node)
        return [node + 1]
      },
      visit: { node, _, _ in visits.append(node) })
    #expect(truncated)
    #expect(reads == [0, 1, 2])
    #expect(visits == reads)
  }

  @Test
  func readFailurePropagatesInsteadOfProducingCompleteObservation() {
    #expect(throws: Failure.self) {
      try MacAccessibilityTraversal.walk(
        root: 0, maximumDepth: 12, maximumElements: 512,
        children: { node, _ in
          if node == 1 { throw Failure() }
          return [1]
        }, visit: { _, _, _ in })
    }
  }

  @Test
  func completeTreeAtExactBudgetIsNotTruncated() throws {
    let truncated = try MacAccessibilityTraversal.walk(
      root: 0, maximumDepth: 12, maximumElements: 2,
      children: { node, _ in node == 0 ? [1] : [] }, visit: { _, _, _ in })
    #expect(!truncated)
  }

  private struct Failure: Error {}
}
