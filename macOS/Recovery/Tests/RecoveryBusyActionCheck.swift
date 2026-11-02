import AppKit

@main struct Check {
  static func frame(_ view: NSView) -> NSRect {
    view.window?.contentView?.layoutSubtreeIfNeeded()
    return view.convert(view.bounds, to: nil)
  }

  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    // Laid out, never ordered on screen.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 80), styleMask: [.borderless],
      backing: .buffered, defer: true)
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 80))
    window.contentView = root

    // A lone primary button stays centred, with its spinner slot to its left.
    let continueButton = RecoveryPrimaryButton(title: "Continue", target: nil, action: nil)
    let action = RecoveryBusyAction(button: continueButton)
    root.addSubview(action)
    NSLayoutConstraint.activate([
      action.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      action.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    var announced: [String] = []
    action.spinner.announce = { announced.append($0) }
    let idle = RecoveryPrimaryAction(title: "Continue", isEnabled: true, wait: nil)
    let waiting = RecoveryPrimaryAction(title: "Continue", isEnabled: false, wait: .verifying)
    action.apply(idle)
    let resting = frame(continueButton)
    precondition(abs(resting.midX - 390) < 0.5, "Continue is not centred: \(resting)")
    precondition(action.spinner.isHidden && continueButton.isEnabled)

    action.apply(waiting)
    action.apply(waiting)
    precondition(frame(continueButton) == resting, "the spinner moved Continue")
    precondition(!action.spinner.isHidden && !continueButton.isEnabled)
    precondition(action.wait == .verifying)
    precondition(announced == [RecoveryWait.verifying.announcement], "announced \(announced)")
    precondition(action.spinner.accessibilityLabel() == RecoveryWait.verifying.announcement)
    precondition(continueButton.accessibilityHelp() == RecoveryWait.verifying.announcement)
    let spinner = frame(action.spinner)
    precondition(
      abs(spinner.maxX + RecoveryBusyAction.gap - resting.minX) < 0.5
        && abs(spinner.midY - resting.midY) < 0.5, "spinner \(spinner) is not left of \(resting)")

    action.apply(idle)
    precondition(frame(continueButton) == resting && action.spinner.isHidden)
    precondition(continueButton.isEnabled && continueButton.accessibilityHelp() == nil)
    precondition(announced.count == 1)

    // Next to other buttons, the slot is balanced after the whole row instead.
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    let restore = RecoveryBusyAction(
      button: RecoveryPrimaryButton(title: "Restore", target: nil, action: nil), balanced: false)
    let proxy = RecoverySecondaryButton(title: "Enable Proxy", target: nil, action: nil)
    row.addArrangedSubview(restore)
    row.addArrangedSubview(proxy)
    row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: RecoveryBusyAction.slot)
    action.removeFromSuperview()
    root.addSubview(row)
    NSLayoutConstraint.activate([
      row.centerXAnchor.constraint(equalTo: root.centerXAnchor),
      row.centerYAnchor.constraint(equalTo: root.centerYAnchor),
    ])
    let visible = frame(restore.button).union(frame(proxy))
    precondition(abs(visible.midX - 390) < 0.5, "the repair row is not centred: \(visible)")
    restore.apply(.init(title: "Restore", isEnabled: false, wait: .verifying))
    precondition(frame(restore.button).union(frame(proxy)) == visible, "the spinner moved the row")

    // In a sheet the spinner sits left of the buttons, which stay put.
    let cancel = RecoverySecondaryButton(title: "Cancel", target: nil, action: nil)
    let install = RecoveryPrimaryButton(title: "Install", target: nil, action: nil)
    let sheetSpinner = RecoveryBusyIndicator()
    sheetSpinner.announce = { _ in }
    let sheet = RecoverySheet(
      title: "Authorize installation", message: "Enter password for the owner.", width: 430,
      height: 230, body: NSView(), bodyHeight: 0, buttons: [cancel, install],
      accessory: sheetSpinner)
    let buttons = frame(cancel).union(frame(install))
    sheetSpinner.show(.verifying)
    precondition(frame(cancel).union(frame(install)) == buttons && !sheetSpinner.isHidden)
    precondition(frame(sheetSpinner).maxX < frame(cancel).minX)
    sheetSpinner.show(nil)
    precondition(sheetSpinner.isHidden)
    _ = sheet
    print(
      "PASS busy primary buttons: centred, spinner on the left, nothing moves, one announcement")
  }
}
