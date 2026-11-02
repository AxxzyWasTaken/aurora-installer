import AppKit

/// Window → Installer Log (Command-L), as in Apple's Installer. The item opens
/// the log window and closes it again; a check mark shows while it is open.
/// The window is the only source of truth: AppKit validates the item whenever
/// the menu opens or its key equivalent is pressed.
enum RecoveryLogMenu {
  static let title = "Installer Log"
  static let keyEquivalent = "l"
  static let identifier = NSUserInterfaceItemIdentifier("installerLog")

  /// Adds the item to the top of the Window menu, above a separator.
  @discardableResult static func addItem(to windows: NSMenu, target: AnyObject, action: Selector)
    -> NSMenuItem
  {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.keyEquivalentModifierMask = [.command]
    item.target = target
    item.identifier = identifier
    windows.insertItem(item, at: 0)
    windows.insertItem(.separator(), at: 1)
    return item
  }

  /// Marks the item while the log is open. It is always available.
  @discardableResult static func validate(_ item: NSMenuItem, showing: Bool) -> Bool {
    let state: NSControl.StateValue = showing ? .on : .off
    if item.state != state { item.state = state }
    return true
  }
}
