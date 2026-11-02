import AppKit

/// A small spinner that shows only while something is waited for. It tells
/// VoiceOver what is being waited for when the wait starts.
final class RecoveryBusyIndicator: NSProgressIndicator {
  static let size: CGFloat = 16
  /// Speaks a message to VoiceOver; tests replace it to record announcements.
  var announce: (String) -> Void = RecoveryBusyIndicator.postAnnouncement
  private(set) var wait: RecoveryWait?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    style = .spinning
    controlSize = .small
    isIndeterminate = true
    isDisplayedWhenStopped = false
    isHidden = true
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: Self.size),
      heightAnchor.constraint(equalToConstant: Self.size),
    ])
  }

  convenience init() { self.init(frame: .zero) }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  func show(_ wait: RecoveryWait?) {
    guard wait != self.wait else { return }
    self.wait = wait
    toolTip = wait?.announcement
    setAccessibilityLabel(wait?.announcement)
    if let wait {
      isHidden = false
      startAnimation(nil)
      announce(wait.announcement)
    } else {
      stopAnimation(nil)
      isHidden = true
    }
  }

  /// The C accessibility call; it needs no Swift AppKit overlay.
  static func postAnnouncement(_ message: String) {
    guard let application = NSApp else { return }
    NSAccessibility.post(
      element: application, notification: .announcementRequested,
      userInfo: [
        .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
  }
}

/// A step's primary button with a spinner to its left that turns while the
/// step waits. The spinner's slot is always reserved, and `balanced` mirrors
/// it on the right so a lone button stays centred: showing or hiding the
/// spinner never moves the button.
final class RecoveryBusyAction: NSView {
  static let gap: CGFloat = 10
  static let slot = RecoveryBusyIndicator.size + gap
  let button: NSButton
  let spinner = RecoveryBusyIndicator()

  init(button: NSButton, balanced: Bool = true) {
    self.button = button
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    button.translatesAutoresizingMaskIntoConstraints = false
    addSubview(spinner)
    addSubview(button)
    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
      button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.slot),
      widthAnchor.constraint(
        equalTo: button.widthAnchor, constant: Self.slot * (balanced ? 2 : 1)),
      spinner.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -Self.gap),
      spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("Use the programmatic initializer") }

  var wait: RecoveryWait? { spinner.wait }

  func apply(_ action: RecoveryPrimaryAction) {
    if button.title != action.title { button.title = action.title }
    button.isEnabled = action.isEnabled
    // A dimmed button explains itself when VoiceOver reaches it.
    button.setAccessibilityHelp(action.wait?.announcement)
    spinner.show(action.wait)
  }
}
