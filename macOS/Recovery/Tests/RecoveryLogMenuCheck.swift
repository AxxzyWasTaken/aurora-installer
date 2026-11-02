import AppKit

/// Stands in for the installer window: one log window, opened and closed by the menu.
final class Logs: NSObject, NSMenuItemValidation {
  var showing = false
  var toggles = 0

  @objc func toggleInstallerLog(_ sender: Any?) {
    toggles += 1
    showing.toggle()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    RecoveryLogMenu.validate(item, showing: showing)
  }
}

@main struct Check {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let logs = Logs()
    let windows = NSMenu(title: "Window")
    windows.addItem(withTitle: "Bring All to Front", action: nil, keyEquivalent: "")
    let item = RecoveryLogMenu.addItem(
      to: windows, target: logs, action: #selector(Logs.toggleInstallerLog(_:)))
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowItem.submenu = windows
    let main = NSMenu()
    main.addItem(windowItem)
    precondition(windows.items.first === item && windows.items[1].isSeparatorItem)
    precondition(item.title == "Installer Log" && item.identifier == RecoveryLogMenu.identifier)
    precondition(item.keyEquivalent == "l" && item.keyEquivalentModifierMask == [.command])
    guard
      let commandL = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false,
        keyCode: 37)
    else { fatalError("no key event") }

    windows.update()
    precondition(item.isEnabled && item.state == .off)
    precondition(main.performKeyEquivalent(with: commandL) && logs.showing)
    windows.update()
    precondition(item.state == .on)
    precondition(main.performKeyEquivalent(with: commandL) && !logs.showing)
    windows.update()
    precondition(item.state == .off)

    // The window closed some other way: the next validation catches up.
    logs.showing = true
    windows.update()
    precondition(item.state == .on && logs.toggles == 2)
    print("PASS Window menu: Installer Log on Command-L follows the log window")
  }
}
