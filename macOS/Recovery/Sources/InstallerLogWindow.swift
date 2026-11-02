import AppKit

/// Window → Installer Log (Command-L), modelled on the Installer Log of Apple's
/// Install macOS app: a level filter, a search field, Save…, and the lines in
/// monospaced text that follows new lines unless the person scrolls up. It is
/// a window of its own, so it stays open beside sheets and while setup runs.
final class InstallerLogWindowController: NSWindowController, NSWindowDelegate,
  NSSearchFieldDelegate
{
  static let filterKey = "InstallerLogFilter"
  /// Told about the window just before it is shown; tests keep it invisible.
  static var willShow: ((NSWindow) -> Void)?
  static let sourceWidth = 12

  private let log: InstallerLog
  let filterButton = NSPopUpButton(frame: .zero, pullsDown: false)
  let searchField = NSSearchField()
  let saveButton = NSButton(title: "Save…", target: nil, action: nil)
  let viewer = LogTextView(text: "")
  let countLabel = NSTextField(labelWithString: "")
  private(set) var filter: InstallerLogFilter
  private(set) var search = ""
  /// The sequences shown, so new lines can be appended in place.
  private var shown: [Int] = []
  private var shownQuery: (InstallerLogFilter, String)?
  private var ticker: Timer?
  private var visibleCount = 0

  init(log: InstallerLog = .shared, filter: InstallerLogFilter? = nil) {
    self.log = log
    let remembered = UserDefaults.standard.object(forKey: Self.filterKey) as? Int
    self.filter =
      filter ?? remembered.flatMap(InstallerLogFilter.init(rawValue:)) ?? .errorsAndProgress
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
      defer: false)
    window.title = RecoveryLogMenu.title
    window.minSize = NSSize(width: 560, height: 300)
    window.isReleasedWhenClosed = false
    // The menu's own item opens it; the window list would name it twice.
    window.isExcludedFromWindowsMenu = true
    window.setFrameAutosaveName("AuroraInstallerLog")
    super.init(window: window)
    window.delegate = self
    build(in: window)
    reload()
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  var isShowing: Bool { window?.isVisible == true }

  func show() {
    guard let window else { return }
    if !window.isVisible {
      Self.willShow?(window)
      if window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
        window.center()
      }
    }
    reload()
    window.makeKeyAndOrderFront(nil)
    startTicker()
  }

  private func build(in window: NSWindow) {
    for item in InstallerLogFilter.allCases { filterButton.addItem(withTitle: item.title) }
    filterButton.selectItem(at: filter.rawValue)
    filterButton.target = self
    filterButton.action = #selector(filterChanged)
    searchField.placeholderString = "Search"
    searchField.sendsSearchStringImmediately = true
    searchField.delegate = self
    saveButton.bezelStyle = .rounded
    saveButton.target = self
    saveButton.action = #selector(savePressed)
    countLabel.font = .systemFont(ofSize: 11)
    countLabel.textColor = .secondaryLabelColor
    countLabel.lineBreakMode = .byTruncatingTail
    viewer.layer?.cornerRadius = 0
    viewer.layer?.borderWidth = 0
    viewer.backgroundColor = .textBackgroundColor
    viewer.drawsBackground = true
    viewer.textView.usesFindBar = true
    viewer.textView.setAccessibilityLabel(RecoveryLogMenu.title)

    let content = NSView()
    let top = NSStackView(views: [filterButton, NSView(), searchField, saveButton])
    top.orientation = .horizontal
    top.spacing = 10
    top.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    top.setHuggingPriority(.defaultHigh, for: .vertical)
    let upper = NSBox()
    upper.boxType = .separator
    let lower = NSBox()
    lower.boxType = .separator
    let footer = NSStackView(views: [countLabel])
    footer.orientation = .horizontal
    footer.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
    for view in [top, upper, viewer, lower, footer] as [NSView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      ])
    }
    NSLayoutConstraint.activate([
      top.topAnchor.constraint(equalTo: content.topAnchor),
      upper.topAnchor.constraint(equalTo: top.bottomAnchor),
      viewer.topAnchor.constraint(equalTo: upper.bottomAnchor),
      lower.topAnchor.constraint(equalTo: viewer.bottomAnchor),
      footer.topAnchor.constraint(equalTo: lower.bottomAnchor),
      footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      searchField.widthAnchor.constraint(equalToConstant: 220),
    ])
    window.contentView = content
  }

  /// Shows the log's current lines under the chosen filter and search.
  func reload() {
    let visible = InstallerLogFormat.visible(log.entries, filter: filter, search: search)
    let sequences = visible.map(\.sequence)
    let sameQuery = shownQuery.map { $0.0 == filter && $0.1 == search } ?? false
    if sameQuery, !shown.isEmpty, shown.count <= sequences.count,
      sequences.first == shown.first, sequences[shown.count - 1] == shown.last
    {
      if shown.count < sequences.count {
        viewer.append(attributed: Self.text(visible[shown.count...], search: search))
      }
    } else if sequences != shown || !sameQuery {
      viewer.update(attributed: Self.text(visible[...], search: search))
    }
    shown = sequences
    shownQuery = (filter, search)
    visibleCount = visible.count
    saveButton.isEnabled = !visible.isEmpty
    updateFooter()
  }

  private func updateFooter() {
    let total = log.entries.count
    var text = visibleCount == total ? "\(total) lines" : "\(visibleCount) of \(total) lines"
    if log.truncated { text += " (newest shown; each attempt’s full log is kept)" }
    let running = log.running
    if !running.isEmpty {
      let now = Date()
      text +=
        "   ·   Running: "
        + running.map { entry in
          let seconds = Int(max(0, now.timeIntervalSince(entry.time)))
          let age =
            seconds < 60
            ? "\(seconds) s" : String(format: "%d min %02d s", seconds / 60, seconds % 60)
          return "\(entry.activity ?? entry.source) (\(age))"
        }.joined(separator: ", ")
    }
    if countLabel.stringValue != text { countLabel.stringValue = text }
  }

  private func startTicker() {
    guard ticker == nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateFooter() }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  func windowWillClose(_ notification: Notification) {
    ticker?.invalidate()
    ticker = nil
  }

  @objc private func filterChanged() {
    filter = InstallerLogFilter(rawValue: filterButton.indexOfSelectedItem) ?? .errorsAndProgress
    UserDefaults.standard.set(filter.rawValue, forKey: Self.filterKey)
    reload()
  }

  /// Sets the filter and search as the person would; renders and tests use it.
  func apply(filter: InstallerLogFilter, search: String) {
    self.filter = filter
    filterButton.selectItem(at: filter.rawValue)
    self.search = search
    searchField.stringValue = search
    reload()
  }

  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as AnyObject? === searchField else { return }
    search = searchField.stringValue
    reload()
  }

  @objc private func savePressed() {
    guard let window else { return }
    let visible = InstallerLogFormat.visible(log.entries, filter: filter, search: search)
    let text = InstallerLogFormat.document(visible, filter: filter, search: search)
    let panel = NSSavePanel()
    let stamp = InstallerLogFormat.timestamp(Date()).prefix(16)
      .replacingOccurrences(of: ":", with: ".")
    panel.nameFieldStringValue = "Aurora Installer Log \(stamp).log"
    panel.canCreateDirectories = true
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      do { try Data(text.utf8).write(to: url, options: .atomic) } catch {
        NSAlert(error: error).beginSheetModal(for: window)
      }
    }
  }

  /// Time, source and message per line, in monospaced text; errors in red.
  static func text(_ entries: ArraySlice<InstallerLogEntry>, search: String) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    let paragraph = NSMutableParagraphStyle()
    // Wrapped lines start under the message, not under the time.
    paragraph.headIndent =
      (String(repeating: " ", count: 14 + sourceWidth + 1) as NSString)
      .size(withAttributes: [.font: font]).width
    let result = NSMutableAttributedString()
    let needle = search.trimmingCharacters(in: .whitespaces)
    for entry in entries {
      let time = InstallerLogFormat.clock(entry.time) + "  "
      let source =
        entry.source.count >= sourceWidth
        ? entry.source + " "
        : entry.source.padding(toLength: sourceWidth, withPad: " ", startingAt: 0) + " "
      result.append(
        NSAttributedString(
          string: time,
          attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.secondaryLabelColor,
          ]))
      result.append(
        NSAttributedString(
          string: source,
          attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.tertiaryLabelColor,
          ]))
      let color: NSColor =
        switch entry.level {
        case .error: .systemRed
        case .progress: .labelColor
        case .debug: .secondaryLabelColor
        }
      let start = result.length
      result.append(
        NSAttributedString(
          string: entry.message + "\n",
          attributes: [
            .font: entry.level == .error ? bold : font, .paragraphStyle: paragraph,
            .foregroundColor: color,
          ]))
      guard !needle.isEmpty else { continue }
      let body = entry.message as NSString
      var range = body.range(of: needle, options: .caseInsensitive)
      while range.location != NSNotFound {
        result.addAttribute(
          .backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.55),
          range: NSRange(location: start + range.location, length: range.length))
        let next = range.location + range.length
        range = body.range(
          of: needle, options: .caseInsensitive,
          range: NSRange(location: next, length: body.length - next))
      }
    }
    return result
  }
}
