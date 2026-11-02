import AppKit
import AuroraAppleInstallerTrustCore
import XCTest

@testable import AuroraAppleInstallerApp

@MainActor
final class InstallerLogWindowTests: XCTestCase {
  func testSearchHighlightsTheSourceColumnToo() {
    let entry = InstallerLogEntry(
      sequence: 1, time: Date(), level: .debug, source: "helper/diskutil", message: "Started #1")
    let text = InstallerLogTextView.text([entry][...], search: "DISKUTIL")
    var marked: [String] = []
    text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) {
      value, range, _ in
      if value != nil { marked.append((text.string as NSString).substring(with: range)) }
    }
    XCTAssertEqual(marked, ["diskutil"])
  }
}
