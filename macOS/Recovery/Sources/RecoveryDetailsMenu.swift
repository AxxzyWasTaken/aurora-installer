import AppKit

/// View → Show Details / Hide Details. The details sheet is the only source of
/// truth: AppKit validates the item whenever the menu opens or its key
/// equivalent is pressed, and validation re-derives the title from the sheet,
/// so the item always says what choosing it will do.
enum RecoveryDetailsMenu {
  static let menuTitle = "View"
  static let showTitle = "Show Details"
  static let hideTitle = "Hide Details"
  /// Command-L, as Apple's Installer uses for its log.
  static let keyEquivalent = "l"
  static let identifier = NSUserInterfaceItemIdentifier("toggleDetails")

  struct State: Equatable {
    var title: String
    var isEnabled: Bool
  }

  /// `available` is false before there is any output to show. Only one sheet
  /// is shown at a time, so another open sheet makes Show Details wait.
  static func state(showing: Bool, available: Bool, otherSheetShowing: Bool) -> State {
    showing
      ? State(title: hideTitle, isEnabled: true)
      : State(title: showTitle, isEnabled: available && !otherSheetShowing)
  }

  /// The View menu's item for the main menu.
  static func makeMenuItem(target: AnyObject, action: Selector) -> NSMenuItem {
    let menu = NSMenu(title: menuTitle)
    let details = menu.addItem(
      withTitle: showTitle, action: action, keyEquivalent: keyEquivalent)
    details.keyEquivalentModifierMask = [.command]
    details.target = target
    details.identifier = identifier
    let item = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
    item.submenu = menu
    return item
  }

  /// Applies `state` to the item and returns whether it is enabled.
  @discardableResult static func validate(_ item: NSMenuItem, state: State) -> Bool {
    if item.title != state.title { item.title = state.title }
    return state.isEnabled
  }
}
