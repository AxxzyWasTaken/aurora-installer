import AppKit

@main struct Check {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let payload = String(repeating: "0123456789abcdef log line\n", count: 2500)
    precondition(payload.utf8.count < 65536)
    let viewer = LogTextView(text: payload)
    viewer.frame = NSRect(x: 0, y: 0, width: 474, height: 200)
    let window = NSWindow(
      contentRect: viewer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = viewer
    viewer.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    guard let container = viewer.textView.textContainer,
      let manager = viewer.textView.layoutManager
    else { fatalError("native log view not created") }
    let started = Date()
    manager.ensureLayout(for: container)
    let bounds = manager.usedRect(for: container)
    precondition(viewer.displayedText == payload)
    precondition(viewer.textView.isSelectable && !viewer.textView.isEditable)
    precondition(bounds.height > 200 && bounds.width > 0 && bounds.width <= 474)
    viewer.update(text: "replacement\n")
    precondition(viewer.displayedText == "replacement\n")

    // In the running app, Auto Layout grew the details log after its text
    // view already had a width, and autoresizing added the growth on top:
    // 948 points of text in a 474-point log, scrolled 253 points sideways,
    // cutting off the start of every line. The log keeps the text as wide as
    // itself and unscrolled sideways whenever it lays out.
    viewer.textView.setFrameSize(NSSize(width: 948, height: viewer.textView.frame.height))
    viewer.contentView.scroll(to: NSPoint(x: 253, y: viewer.contentView.bounds.origin.y))
    viewer.tile()
    precondition(
      viewer.textView.frame.width == viewer.contentSize.width,
      "log text is \(viewer.textView.frame.width) wide in a \(viewer.contentSize.width) log")
    precondition(viewer.contentView.bounds.origin.x == 0, "log scrolled sideways")
    print(
      "PASS native selectable log viewer: \(payload.utf8.count) bytes, layout \(bounds.width)x\(bounds.height), layout check \(Date().timeIntervalSince(started))s"
    )
    window.orderOut(nil)
  }
}
