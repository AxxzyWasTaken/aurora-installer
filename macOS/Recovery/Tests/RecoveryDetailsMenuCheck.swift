import AppKit

/// Stands in for the installer window: one details sheet, opened and closed by the menu.
final class Details: NSObject, NSMenuItemValidation {
  var showing = false
  var available = true
  var otherSheet = false
  var toggles = 0

  @objc func toggleDetails(_ sender: Any?) {
    toggles += 1
    if showing {
      showing = false
    } else if !otherSheet && available {
      showing = true
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    RecoveryDetailsMenu.validate(
      item,
      state: RecoveryDetailsMenu.state(
        showing: showing, available: available, otherSheetShowing: otherSheet))
  }
}

@main struct Check {
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    typealias Menu = RecoveryDetailsMenu
    precondition(
      Menu.state(showing: false, available: true, otherSheetShowing: false)
        == .init(title: "Show Details", isEnabled: true))
    precondition(
      Menu.state(showing: true, available: true, otherSheetShowing: true)
        == .init(title: "Hide Details", isEnabled: true))
    precondition(!Menu.state(showing: false, available: false, otherSheetShowing: false).isEnabled)
    precondition(!Menu.state(showing: false, available: true, otherSheetShowing: true).isEnabled)

    let details = Details()
    let viewItem = Menu.makeMenuItem(target: details, action: #selector(Details.toggleDetails(_:)))
    let main = NSMenu()
    main.addItem(viewItem)
    guard let menu = viewItem.submenu, let item = menu.items.first, menu.items.count == 1 else {
      fatalError("View menu not built")
    }
    precondition(viewItem.title == "View" && menu.title == "View")
    precondition(item.identifier == Menu.identifier && item.target === details)
    precondition(item.keyEquivalent == "l" && item.keyEquivalentModifierMask == [.command])
    guard
      let commandL = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
        context: nil, characters: "l", charactersIgnoringModifiers: "l", isARepeat: false,
        keyCode: 37)
    else { fatalError("no key event") }

    menu.update()
    precondition(item.title == "Show Details" && item.isEnabled)
    precondition(main.performKeyEquivalent(with: commandL) && details.showing)
    menu.update()
    precondition(item.title == "Hide Details" && item.isEnabled)
    precondition(main.performKeyEquivalent(with: commandL) && !details.showing)
    menu.update()
    precondition(item.title == "Show Details")

    // The sheet closed some other way: the next validation catches up.
    details.showing = true
    menu.update()
    precondition(item.title == "Hide Details")
    details.showing = false
    menu.update()
    precondition(item.title == "Show Details")

    // Disabled items do not fire their action.
    details.otherSheet = true
    menu.update()
    precondition(!item.isEnabled)
    let before = details.toggles
    _ = main.performKeyEquivalent(with: commandL)
    precondition(details.toggles == before && !details.showing)
    print("PASS View menu: Show/Hide Details on Command-L follows the details sheet")
  }
}
