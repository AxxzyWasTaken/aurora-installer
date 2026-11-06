import Foundation

@main struct BootSelectionCheck {
  static func main() throws {
    precondition(
      RecoveryBootPolicy.authorizationArguments(groupUUID: "target") == ["-nc", "-v", "target"])
    precondition(
      RecoveryBootPolicy.authorizationArguments(
        groupUUID: "target", allowCustomBootArguments: true) == ["-nca", "-v", "target"])
    let volume = "/Volumes/Volume With Spaces"
    // Every Mach-O chip enrolls a padded object with --compress, and never --raw.
    for chip: UInt64 in [0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050, 0x6051, 0x6052, 0x8150] {
      let mode = AuraBootMode.required(chipID: chip)
      precondition(mode == .macho, String(chip, radix: 16))
      precondition(mode.executeWindowSize == 128 << 20)
      precondition(mode.stage1Path == "macho/aura-boot.macho")
      let stage1 = "/payloads/" + mode.stage1Path
      precondition(
        mode.enrollmentArguments(stage1: stage1, volume: volume)
          == ["configure-boot", "-c", stage1, "-v", volume, "--compress"])
    }
    // Every M1 to M3 chip keeps the raw arguments byte for byte, with no window.
    for chip: UInt64 in [
      0x8103, 0x6000, 0x6001, 0x6002, 0x8112, 0x6020, 0x6021, 0x6022, 0x8122, 0x6030, 0x6031,
      0x6032, 0x6034,
    ] {
      let mode = AuraBootMode.required(chipID: chip)
      precondition(mode == .raw, String(chip, radix: 16))
      precondition(mode.executeWindowSize == nil)
      precondition(mode.stage1Path == "raw/aura-raw.bin")
      let stage1 = "/payloads/" + mode.stage1Path
      precondition(
        mode.enrollmentArguments(stage1: stage1, volume: volume)
          == [
            "configure-boot", "-c", stage1, "-v", volume, "--raw", "--entry-point", "2048",
            "--lowest-virtual-address", "0",
          ])
    }
    // The payload keeps one Stage 2 under one name; the configuration says where it goes.
    for mode in [AuraBootMode.raw, .macho] {
      precondition(mode.stage2Path == "raw/boot.bin")
      let restored = try JSONDecoder().decode(
        BootSelection.self, from: JSONEncoder().encode(BootSelection(mode: mode)))
      precondition(restored.mode == mode)
    }
    precondition(AuraStage1Format.stage2Path(machO: true) == "m1n1/boot-ctxr.bin")
    precondition(AuraStage1Format.stage2Path(machO: false) == "m1n1/boot.bin")
    print(
      "PASS every Mach-O chip pads and compresses; M1 to M3 raw arguments unchanged; no window on raw; Stage 2 path per mode; paths with spaces; JSON round trip"
    )
  }
}
