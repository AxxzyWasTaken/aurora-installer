import AppKit

/// A bounded, selectable native log view that preserves the user's scroll position.
final class LogTextView: NSScrollView {
  private let editor: NSTextView

  init(text: String) {
    editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 474, height: 200))
    super.init(frame: .zero)
    hasVerticalScroller = true
    autohidesScrollers = true
    drawsBackground = true
    backgroundColor = AuroraTheme.window
    wantsLayer = true
    layer?.cornerRadius = AuroraTheme.buttonRadius
    layer?.borderColor = AuroraTheme.darkCGColor(AuroraTheme.separator)
    layer?.borderWidth = 1
    editor.isEditable = false
    editor.isSelectable = true
    editor.isRichText = false
    editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    editor.textColor = .textColor
    editor.drawsBackground = false
    editor.textContainerInset = NSSize(width: 12, height: 12)
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainer?.containerSize = NSSize(
      width: 474, height: CGFloat.greatestFiniteMagnitude)
    documentView = editor
    update(text: text)
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  /// Autoresizing adds every change in the visible width to the text view's
  /// width, so a log created before its sheet is laid out could end up twice
  /// as wide as it shows, and scrolling to the end then scrolled sideways and
  /// cut off the start of every line. Keep the text exactly as wide as the view.
  override func tile() {
    super.tile()
    let width = contentSize.width
    guard width > 0 else { return }
    if editor.frame.width != width {
      editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
    }
    if contentView.bounds.origin.x != 0 {
      contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
      reflectScrolledClipView(contentView)
    }
  }

  var displayedText: String { editor.string }
  var textView: NSTextView { editor }

  func update(text: String) {
    guard editor.string != text else { return }
    change { _ in editor.string = text }
  }

  /// Replaces the styled text, keeping the reader's place.
  func update(attributed text: NSAttributedString) {
    change { $0.setAttributedString(text) }
  }

  /// Adds styled text at the end, keeping the reader's place.
  func append(attributed text: NSAttributedString) {
    guard text.length > 0 else { return }
    change { $0.append(text) }
  }

  /// Follows the end while the reader is there; otherwise keeps their
  /// selection and scroll position.
  private func change(_ edit: (NSTextStorage) -> Void) {
    guard let storage = editor.textStorage else { return }
    let atEnd = editor.string.isEmpty || contentView.bounds.maxY >= editor.bounds.maxY - 24
    let selection = editor.selectedRange()
    edit(storage)
    if atEnd {
      editor.scrollRangeToVisible(NSRange(location: editor.string.utf16.count, length: 0))
    } else {
      let count = editor.string.utf16.count
      let start = min(selection.location, count)
      editor.setSelectedRange(
        NSRange(location: start, length: min(selection.length, count - start)))
    }
  }
}
