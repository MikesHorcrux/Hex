import AppKit
import HexCore
import SwiftUI
import Testing

@testable import Hex

/// Opt-in component renders use only static data. They never start a resident or load user settings.
@Suite("Approval menu component rendering")
struct HexApprovalModeRenderingTests {
  @Test @MainActor
  func renderPermissionOptionsForVisualReview() throws {
    guard let path = ProcessInfo.processInfo.environment["HEX_PERMISSION_PREVIEW_DIRECTORY"] else {
      return
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for appearance in [ColorScheme.light, .dark] {
      let appearanceName = appearance == .light ? "light" : "dark"
      let renderer = ImageRenderer(
        content: HexApprovalModeOptionsView(
          selectedMode: .fullAccess,
          scopeDescription: "For this conversation, starting with its next turn.",
          onSelect: { _ in }
        )
        .environment(\.colorScheme, appearance))
      renderer.scale = 2
      let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(to: directory.appendingPathComponent("permissions-\(appearanceName).png"))
    }
  }
}
