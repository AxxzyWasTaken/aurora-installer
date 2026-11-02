import AppKit
import XCTest

@testable import AuroraRecovery

/// Drives the real window controller through the preview build's simulated
/// flow. The window and its sheets stay fully transparent and ignore the mouse.
final class InstallerViewStateTests: XCTestCase {
  private static let checkSeconds = 0.6
  private var window: InstallerWindow?
  private var sheetObserver: NSObjectProtocol?

  override class func setUp() {
    super.setUp()
    // The model reads these when it is created, like the app's own launch.
    // `swift test` cannot pass app arguments, so add them here; Swift marks
    // this setter deprecated but still honours it.
    if !CommandLine.arguments.contains("--preview") {
      CommandLine.arguments += ["--preview", "--preview-check-seconds=\(checkSeconds)"]
    }
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
  }

  override func setUp() {
    super.setUp()
    XCTAssertTrue(RecoveryActions.isPreview, "UI state tests need the preview build")
    XCTAssertEqual(PreviewTiming.environmentCheck, Self.checkSeconds)
  }

  override func tearDown() {
    if let window {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.orderOut(nil)
    }
    window = nil
    if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }
    sheetObserver = nil
    super.tearDown()
  }

  private func show(_ model: InstallerModel) -> (InstallerWindow, InstallerView) {
    let window = InstallerWindow()
    let controller = InstallerView(model: model)
    window.contentViewController = controller
    window.setFrame(NSRect(x: 0, y: 0, width: 780, height: 660), display: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    // Sheets need their window on screen; keep every sheet invisible too.
    sheetObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willBeginSheetNotification, object: window, queue: nil
    ) { _ in
      for other in NSApp.windows where other !== window {
        other.alphaValue = 0
        other.ignoresMouseEvents = true
      }
    }
    window.orderFrontRegardless()
    window.layoutIfNeeded()
    self.window = window
    return (window, controller)
  }

  private func spin(_ seconds: Double = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  private func wait(
    _ what: String, timeout: Double = 5, file: StaticString = #filePath, line: UInt = #line,
    until condition: () -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { spin() }
    XCTAssertTrue(condition(), "timed out waiting for " + what, file: file, line: line)
  }

  private func views<T: NSView>(_ type: T.Type, in root: NSView?) -> [T] {
    guard let root else { return [] }
    return root.subviews.flatMap { [$0 as? T].compactMap { $0 } + views(type, in: $0) }
  }

  private func primary(_ controller: InstallerView) throws -> RecoveryBusyAction {
    try XCTUnwrap(views(RecoveryBusyAction.self, in: controller.view).first)
  }

  private func frame(_ view: NSView) -> NSRect {
    view.window?.contentView?.layoutSubtreeIfNeeded()
    return view.convert(view.bounds, to: nil)
  }

  private func button(_ title: String, in root: NSView?) -> NSButton? {
    views(NSButton.self, in: root).first { $0.title == title }
  }

  func testLaunchCheckSpinsLeftOfACentredDisabledContinue() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    let action = try primary(controller)
    XCTAssertEqual(action.button.title, "Continue")
    let idle = frame(action.button)
    XCTAssertEqual(idle.midX, window.frame.width / 2, accuracy: 0.5, "Continue is centred")
    XCTAssertTrue(action.button.isEnabled)
    XCTAssertTrue(action.spinner.isHidden)

    var announced: [String] = []
    action.spinner.announce = { announced.append($0) }
    model.checkEnrollmentEnvironment()
    XCTAssertTrue(model.checkingEnvironment)
    XCTAssertFalse(action.button.isEnabled)
    XCTAssertFalse(action.spinner.isHidden)
    XCTAssertEqual(action.wait, .verifying)
    XCTAssertEqual(announced, [RecoveryWait.verifying.announcement])
    XCTAssertEqual(action.button.accessibilityHelp(), RecoveryWait.verifying.announcement)
    XCTAssertEqual(frame(action.button), idle, "the spinner must not move Continue")
    let spinner = frame(action.spinner)
    XCTAssertLessThan(spinner.maxX, idle.minX, "the spinner turns left of Continue")
    XCTAssertEqual(spinner.midY, idle.midY, accuracy: 0.5)

    wait("the launch check") { !model.checkingEnvironment }
    XCTAssertTrue(model.environmentVerified)
    XCTAssertTrue(action.button.isEnabled)
    XCTAssertTrue(action.spinner.isHidden)
    XCTAssertNil(action.button.accessibilityHelp())
    XCTAssertEqual(frame(action.button), idle)
    XCTAssertEqual(announced.count, 1, "one announcement per wait")
  }

  func testContinueAsksAtOnceAndInstallWaitsForTheRepeatedCheck() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    let action = try primary(controller)
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified }

    action.button.performClick(nil)
    // The prompt opens without waiting; the same check runs again behind it.
    let sheet = try XCTUnwrap(window.attachedSheet, "the password prompt opens at once")
    XCTAssertTrue(model.checkingEnvironment, "Continue repeats the check")
    XCTAssertEqual(action.wait, .verifying)
    let field = try XCTUnwrap(views(NSSecureTextField.self, in: sheet.contentView).first)
    let install = try XCTUnwrap(button("Install", in: sheet.contentView))
    let sheetSpinner = try XCTUnwrap(
      views(RecoveryBusyIndicator.self, in: sheet.contentView).first)
    XCTAssertTrue(sheetSpinner.isHidden, "nothing waits until Install is pressed")
    XCTAssertTrue(install.isEnabled)
    let installFrame = frame(install)

    field.stringValue = "preview password"
    install.performClick(nil)
    XCTAssertEqual(model.stage, .welcome, "installation waits for the check")
    XCTAssertFalse(sheetSpinner.isHidden)
    XCTAssertEqual(sheetSpinner.wait, .verifying)
    XCTAssertFalse(install.isEnabled)
    XCTAssertFalse(field.isEnabled)
    XCTAssertEqual(frame(install), installFrame, "the spinner must not move Install")
    XCTAssertLessThan(frame(sheetSpinner).maxX, frame(install).minX)
    XCTAssertTrue(window.attachedSheet === sheet)

    wait("installation to start") { model.stage == .installing }
    XCTAssertNil(window.attachedSheet, "the prompt closes once the check passes")
    XCTAssertTrue(model.password.isEmpty, "the preview consumes the password")
    XCTAssertTrue(field.stringValue.isEmpty)
  }

  func testCancelWhileWaitingKeepsThePromptClosed() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    model.checkEnrollmentEnvironment()
    wait("the launch check") { model.environmentVerified }
    try primary(controller).button.performClick(nil)
    let sheet = try XCTUnwrap(window.attachedSheet)
    try XCTUnwrap(views(NSSecureTextField.self, in: sheet.contentView).first).stringValue = "x"
    try XCTUnwrap(button("Install", in: sheet.contentView)).performClick(nil)
    try XCTUnwrap(button("Cancel", in: sheet.contentView)).performClick(nil)
    XCTAssertNil(window.attachedSheet)
    wait("the repeated check") { !model.checkingEnvironment }
    spin(0.2)
    XCTAssertEqual(model.stage, .welcome, "a cancelled prompt never installs")
    XCTAssertNil(window.attachedSheet)
  }

  func testEveryPrimaryButtonWaitsInPlace() throws {
    let model = InstallerModel()
    let (_, controller) = show(model)
    model.stage = .account
    model.accountUsername = "aurora-owner"
    model.accountPassword = "secret"
    model.accountConfirmation = "secret"
    var action = try primary(controller)
    XCTAssertEqual(action.button.title, "Create Account")
    XCTAssertTrue(action.button.isEnabled)
    var idle = frame(action.button)
    XCTAssertEqual(idle.midX, 390, accuracy: 0.5)
    model.creatingAccount = true
    XCTAssertEqual(action.wait, .creatingAccount)
    XCTAssertEqual(action.button.title, "Create Account", "the title stays while it waits")
    XCTAssertFalse(action.button.isEnabled)
    XCTAssertEqual(frame(action.button), idle)
    model.creatingAccount = false

    model.stage = .complete
    action = try primary(controller)
    XCTAssertEqual(action.button.title, "Restart")
    idle = frame(action.button)
    XCTAssertEqual(idle.midX, 390, accuracy: 0.5)
    model.restartingCompletedSetup = true
    XCTAssertEqual(action.wait, .restarting)
    XCTAssertFalse(action.button.isEnabled)
    XCTAssertEqual(frame(action.button), idle)
    model.restartingCompletedSetup = false
    XCTAssertTrue(action.spinner.isHidden)
  }

  func testAccountFormExplainsADisabledCreateAccount() throws {
    let model = InstallerModel()
    let (_, controller) = show(model)
    model.stage = .account
    let action = try primary(controller)
    let hint = try XCTUnwrap(
      views(NSTextField.self, in: controller.view).first {
        $0.textColor == AuroraTheme.danger
      })
    XCTAssertTrue(hint.isHidden, "an empty form is not an error")
    model.accountUsername = "Aurora Owner"
    XCTAssertFalse(hint.isHidden)
    XCTAssertEqual(hint.stringValue, RecoveryAccountForm.usernameProblem)
    XCTAssertFalse(action.button.isEnabled)
    model.accountUsername = "aurora-owner"
    model.accountPassword = "secret"
    model.accountConfirmation = "secr"
    XCTAssertTrue(hint.isHidden, "a half-typed confirmation is not reported")
    model.accountConfirmation = "secrex"
    XCTAssertEqual(hint.stringValue, RecoveryAccountForm.mismatch)
    XCTAssertFalse(action.button.isEnabled)
    model.accountConfirmation = "secret"
    XCTAssertTrue(hint.isHidden)
    XCTAssertTrue(action.button.isEnabled)
  }

  func testViewMenuShowsAndHidesDetails() throws {
    let model = InstallerModel()
    let (window, controller) = show(model)
    XCTAssertTrue(
      views(NSButton.self, in: controller.view).allSatisfy {
        !$0.title.localizedCaseInsensitiveContains("details")
      }, "details are no longer a button in the window")
    let viewItem = RecoveryDetailsMenu.makeMenuItem(
      target: controller, action: #selector(InstallerView.toggleDetails(_:)))
    let mainMenu = NSMenu()
    mainMenu.addItem(viewItem)
    let menu = try XCTUnwrap(viewItem.submenu)
    let item = try XCTUnwrap(menu.items.first)
    XCTAssertEqual(viewItem.title, "View")
    XCTAssertEqual(item.keyEquivalent, "l")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    let commandL = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "l",
        charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
    func validated() -> (String, Bool) {
      menu.update()
      return (item.title, item.isEnabled)
    }

    XCTAssertTrue(validated() == ("Show Details", false), "nothing to show before any output")
    model.operations = (1...6).map { "Step \($0) of the simulated installation — simulated" }
    model.stage = .complete
    XCTAssertTrue(validated() == ("Show Details", true))

    XCTAssertTrue(mainMenu.performKeyEquivalent(with: commandL))
    let details = try XCTUnwrap(window.attachedSheet)
    let log = try XCTUnwrap(views(LogTextView.self, in: details.contentView).first)
    spin(0.3)
    // The log must not be wider than it shows, or each line's start is cut off.
    XCTAssertEqual(log.textView.frame.width, log.contentSize.width)
    XCTAssertEqual(log.contentView.bounds.origin.x, 0)
    XCTAssertTrue(validated() == ("Hide Details", true))
    XCTAssertTrue(mainMenu.performKeyEquivalent(with: commandL))
    XCTAssertNil(window.attachedSheet)
    XCTAssertTrue(validated() == ("Show Details", true))

    // Closing the sheet itself keeps the menu in step.
    controller.toggleDetails(item)
    let reopened = try XCTUnwrap(window.attachedSheet)
    try XCTUnwrap(button("Done", in: reopened.contentView)).performClick(nil)
    XCTAssertNil(window.attachedSheet)
    XCTAssertTrue(validated() == ("Show Details", true))

    // Another sheet is open: details wait for it.
    model.previewNotice = ("Restart simulated", "This preview does not restart your Mac.")
    let notice = try XCTUnwrap(window.attachedSheet)
    XCTAssertTrue(validated() == ("Show Details", false))
    _ = mainMenu.performKeyEquivalent(with: commandL)
    spin(0.2)
    XCTAssertTrue(window.attachedSheet === notice, "Command-L leaves the open sheet alone")
    XCTAssertTrue(views(LogTextView.self, in: notice.contentView).isEmpty)
  }
}
