// Based on aurora-audio-dsp by saku (MIT). Synthetic data only: no Apple
// tuning file is used or stored by these tests.
#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  final class NativeAudioTuningInputsTests: XCTestCase {
    private func snapshot(spts: Data? = Data([2, 0, 22, 6])) -> NativeAudioTuningInputs.Snapshot {
      NativeAudioTuningInputs.Snapshot(
        acousticID: 35, thieleSmall: spts,
        files: [
          "ADM/config.plist": Data("synthetic config".utf8),
          "DSP/Strips/aid35-aufx-spp3-appl.plist": Data("synthetic spp3".utf8),
        ], build: "00A000")
    }

    func testAcousticIDIsOneLittleEndianWord() {
      XCTAssertEqual(NativeAudioTuningInputs.acousticID(Data([0x23, 0, 0, 0])), 35)
      XCTAssertEqual(NativeAudioTuningInputs.acousticID(Data([0x2c, 0, 0, 0])), 44)
      XCTAssertNil(NativeAudioTuningInputs.acousticID(Data([0x23])))
      XCTAssertNil(NativeAudioTuningInputs.acousticID(Data([0, 0, 0, 0])))
      XCTAssertNil(NativeAudioTuningInputs.acousticID(Data([0xff, 0xff, 0xff, 0xff])))
      XCTAssertEqual(NativeAudioTuningInputs.folder(35), "AID35")
    }

    func testSidecarsAndEscapesAreNotTuning() {
      XCTAssertTrue(NativeAudioTuningInputs.admitted("DSP/Graphs/builtin_speaker_out.dspg"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted("DSP/._builtin_speaker_out.dspg"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted(".DS_Store"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted("../AID9/ADM/config.plist"))
      XCTAssertFalse(NativeAudioTuningInputs.admitted("/System/Library"))
    }

    func testFilesCarryTheFolderTheRecordAndAHashedManifest() throws {
      let files = try NativeAudioTuningInputs.files(
        snapshot(), prefix: NativeAudioTuningInputs.packagePrefix)
      XCTAssertEqual(
        Set(files.keys),
        [
          "apple/audio-tuning/AID35/ADM/config.plist",
          "apple/audio-tuning/AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",
          "apple/audio-tuning/speaker-thiele-small.bin",
          "apple/audio-tuning/manifest.json",
        ])
      let manifest = try JSONDecoder().decode(
        NativeAudioTuningInputs.Manifest.self,
        from: XCTUnwrap(files["apple/audio-tuning/manifest.json"]))
      XCTAssertEqual(manifest.schema, 1)
      XCTAssertEqual(manifest.acousticID, 35)
      XCTAssertEqual(manifest.aid, "AID35")
      XCTAssertEqual(manifest.macOSBuild, "00A000")
      XCTAssertEqual(manifest.basedOn, "aurora-audio-dsp by saku (MIT)")
      XCTAssertEqual(
        manifest.files.map(\.path),
        [
          "AID35/ADM/config.plist", "AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",
        ])
      for record in manifest.files {
        let data = try XCTUnwrap(files["apple/audio-tuning/" + record.path])
        XCTAssertEqual(record.bytes, data.count)
        XCTAssertEqual(record.sha256, NativeStubFileStore.hash(data))
      }
      XCTAssertEqual(manifest.speakerThieleSmall?.bytes, 4)
    }

    func testDesktopWithoutCalibrationStillGetsItsTuning() throws {
      let files = try NativeAudioTuningInputs.files(
        snapshot(spts: nil), prefix: NativeAudioTuningInputs.fallbackPrefix)
      XCTAssertNotNil(files["audio-tuning/AID35/ADM/config.plist"])
      XCTAssertNil(files["audio-tuning/speaker-thiele-small.bin"])
      let manifest = try JSONDecoder().decode(
        NativeAudioTuningInputs.Manifest.self,
        from: XCTUnwrap(files["audio-tuning/manifest.json"]))
      XCTAssertNil(manifest.speakerThieleSmall)
    }

    func testNoSnapshotIsNoFiles() throws {
      XCTAssertTrue(try NativeAudioTuningInputs.files(nil, prefix: "x/").isEmpty)
    }

    func testInvalidSnapshotsAreRejectedAndCollectionNeverStopsAnInstall() throws {
      var empty = snapshot()
      empty.files = [:]
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(empty, prefix: "x/"))
      var escaping = snapshot()
      escaping.files["../outside"] = Data([1])
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(escaping, prefix: "x/"))
      var oversized = snapshot()
      oversized.thieleSmall = Data(count: 8192)
      XCTAssertThrowsError(try NativeAudioTuningInputs.files(oversized, prefix: "x/"))

      let invalid = escaping
      let rejected = try NativeAudioTuningInputs.collect({ _ in invalid }, owner: 0)
      XCTAssertTrue(rejected.package.isEmpty && rejected.fallback.isEmpty)
      struct Failure: Error {}
      let failed = try NativeAudioTuningInputs.collect({ _ in throw Failure() }, owner: 0)
      XCTAssertTrue(failed.package.isEmpty && failed.fallback.isEmpty)
      XCTAssertThrowsError(
        try NativeAudioTuningInputs.collect({ _ in throw CancellationError() }, owner: 0))
      let good = snapshot()
      let collected = try NativeAudioTuningInputs.collect({ _ in good }, owner: 0)
      XCTAssertEqual(collected.package.count, 4)
      XCTAssertEqual(collected.fallback.count, 4)
    }
  }
#endif
