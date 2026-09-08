import AppKit

/// Disposable local qualification window. Contains no user files or external service access.
@main
struct HexObserveActVerifyFixture {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let controller = Controller()
    controller.window.orderFrontRegardless()
    print("FIXTURE_PID=\(ProcessInfo.processInfo.processIdentifier)")
    print("FIXTURE_WINDOW_ID=\(controller.window.windowNumber)")
    fflush(stdout)
    withExtendedLifetime(controller) { application.run() }
  }

  @MainActor
  private final class Controller: NSObject {
    let window: NSWindow
    let result = NSTextField(labelWithString: "No action has been applied")
    private var count = 0

    override init() {
      window = NSWindow(
        contentRect: NSRect(x: 150, y: 180, width: 560, height: 250),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      super.init()
      window.title = "Hex Observe Act Verify Fixture"
      window.isReleasedWhenClosed = false
      let field = NSTextField(string: "Synthetic Hex qualification text")
      field.identifier = NSUserInterfaceItemIdentifier("hex-fixture-text")
      field.setAccessibilityIdentifier("hex-fixture-text")
      field.frame = NSRect(x: 24, y: 170, width: 500, height: 28)
      let button = NSButton(title: "Apply synthetic change", target: self, action: #selector(apply))
      button.identifier = NSUserInterfaceItemIdentifier("hex-fixture-apply")
      button.setAccessibilityIdentifier("hex-fixture-apply")
      button.frame = NSRect(x: 24, y: 110, width: 220, height: 32)
      result.identifier = NSUserInterfaceItemIdentifier("hex-fixture-result")
      result.setAccessibilityIdentifier("hex-fixture-result")
      result.frame = NSRect(x: 24, y: 55, width: 500, height: 28)
      window.contentView?.addSubview(field)
      window.contentView?.addSubview(button)
      window.contentView?.addSubview(result)
    }

    @objc private func apply() {
      count += 1
      result.stringValue = "Applied synthetic change \(count)"
    }
  }
}
