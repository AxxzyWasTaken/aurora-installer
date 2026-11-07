#if os(macOS)
  import XCTest

  @testable import AuroraInstallerUXCore

  final class Stage1CautionTests: XCTestCase {
    func testOnlyTheUntriedM3UltraAndM4BoardsAreWarnedAndNotBlocked() {
      let untried = [
        "j575d", "j614s", "j604", "j623", "j624", "j715", "j773g", "j614c", "j773s", "j575c",
      ]
      for board in untried {
        XCTAssertNotNil(Stage1Caution.reason(for: "apple," + board), board)
      }
      let others = [
        "j274", "j413", "j616s", "j616c", "j713", "j700", "j314s", "j316s", "j314c", "j316c",
        "j375c", "j375d",
      ]
      for board in others {
        XCTAssertNil(Stage1Caution.reason(for: "apple," + board), board)
      }
    }

    func testTheAcknowledgementNamesTheRiskAndTheRecoveryIsSpelledOut() {
      let text = PlainLanguage.planAcknowledgement(resizesMacOS: false, stage1Caution: true)
      XCTAssertEqual(
        text,
        "I have a current backup and approve the disk layout above, and I understand Aurora may not start on this Mac."
      )
      XCTAssertEqual(
        PlainLanguage.planAcknowledgement(resizesMacOS: true, stage1Caution: false),
        PlainLanguage.planAcknowledgement(resizesMacOS: true))
      XCTAssertTrue(PlainLanguage.stage1CautionRecovery.contains("Always Use"))
      XCTAssertTrue(PlainLanguage.stage1CautionRecovery.contains("Erase Linux"))
      XCTAssertFalse(PlainLanguage.stage1CautionRecovery.contains("—"))
    }
  }
#endif
