import Foundation

@main struct BootSelectionCheck {
  static func main() throws {
    precondition(
      RecoveryBootPolicy.authorizationArguments(groupUUID: "target") == ["-nc", "-v", "target"])
    precondition(
      RecoveryBootPolicy.authorizationArguments(
        groupUUID: "target", allowCustomBootArguments: true) == ["-nca", "-v", "target"])
    let initial = BootSelection()
    precondition(initial.mode == .raw && !initial.nestedVirtualization)
    let volume = "/Volumes/Volume With Spaces"
    for macho in [false, true] {
      for nv in [false, true] {
        let selection = BootSelection(machoEnabled: macho, nestedVirtualization: nv)
        precondition(!selection.nestedVirtualization || selection.mode == .macho)
        let stage1 = "/payloads/" + selection.mode.stage1Path
        let arguments = selection.mode.enrollmentArguments(stage1: stage1, volume: volume)
        precondition(arguments[0] == "configure-boot")
        precondition(arguments[2] == stage1 && arguments[4] == volume)
        precondition(selection.mode.stage2Path == "raw/boot.bin")
        if macho {
          precondition(arguments.count == 5)
          precondition(selection.mode.stage1Path == "macho/aura-boot.macho")
        } else {
          precondition(
            Array(arguments.dropFirst(5)) == [
              "--raw", "--entry-point", "2048", "--lowest-virtual-address", "0",
            ])
          precondition(selection.mode.stage1Path == "raw/aura-raw.bin")
        }
        let restored = try JSONDecoder().decode(
          BootSelection.self, from: JSONEncoder().encode(selection))
        precondition(
          restored.mode == selection.mode
            && restored.nestedVirtualization == selection.nestedVirtualization)
      }
    }
    // Recovery's NV2 switch appends a Stage 2 configuration line and replaces
    // only one it appended; whatever came before it is kept byte for byte.
    let gzipEnd = Data([0x1F, 0x8B, 0x08, 0x00, 0x42, 0x0A, 0x00, 0x00])
    for base in [gzipEnd, gzipEnd + Data("chosen.asahi,t8122-gpu=1\n".utf8)] {
      let on = NestedVirtualizationSetting.stage2(base, enabled: true)
      precondition(on == base + Data("chosen.aura,nv2=1\n".utf8))
      let off = NestedVirtualizationSetting.stage2(on, enabled: false)
      precondition(off.prefix(base.count) == base && off.count <= on.count + 18)
      precondition(off.suffix(18) == Data("chosen.aura,nv2=0\n".utf8))
      var toggled = off
      for index in 0..<20 {
        toggled = NestedVirtualizationSetting.stage2(toggled, enabled: index % 2 == 0)
      }
      precondition(toggled.prefix(base.count) == base && toggled.count <= base.count + 36)
      precondition(toggled.suffix(18) == Data("chosen.aura,nv2=0\n".utf8))
    }
    let configured = gzipEnd + Data("chosen.aura,nv2=1\n".utf8)
    precondition(
      NestedVirtualizationSetting.stage2(configured, enabled: false)
        == configured + Data("chosen.aura,nv2=0\n".utf8))
    print(
      "PASS default raw; all four option combinations; exact raw/Mach-O argument separation; shared Stage 2; paths with spaces; JSON round trip; NV2 Stage 2 line"
    )
  }
}
