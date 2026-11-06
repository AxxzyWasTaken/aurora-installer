import Foundation

enum AuraBootMode: String, Codable {
  case raw
  case macho

  /// The only mode a chip may enroll. A Mach-O chip has no raw or unpadded choice.
  static func required(chipID: UInt64) -> AuraBootMode {
    AuraStage1Format.usesMachO(chipID: chipID) ? .macho : .raw
  }

  var stage1Path: String {
    self == .raw ? "raw/aura-raw.bin" : "macho/aura-boot.macho"
  }

  /// The Recovery payload keeps the Stage 2 this installation chainloads under
  /// one name in both modes. `stage2Path` in its configuration says where it goes.
  var stage2Path: String { "raw/boot.bin" }

  /// The code window a Mach-O Stage 1 is padded for. A raw image has none.
  var executeWindowSize: UInt64? { self == .macho ? ExecuteWindow.size : nil }

  /// A Mach-O payload is padded, and `--compress` stores it with LZFSE in
  /// Preboot, as the stock kernelcache is stored.
  func enrollmentArguments(stage1: String, volume: String) -> [String] {
    var arguments = ["configure-boot", "-c", stage1, "-v", volume]
    if self == .raw {
      arguments += ["--raw", "--entry-point", "2048", "--lowest-virtual-address", "0"]
    } else {
      arguments.append("--compress")
    }
    return arguments
  }
}

struct BootSelection: Codable {
  let mode: AuraBootMode
}

enum RecoveryBootPolicy {
  static func authorizationArguments(
    groupUUID: String, allowCustomBootArguments: Bool = false
  ) -> [String] {
    [allowCustomBootArguments ? "-nca" : "-nc", "-v", groupUUID]
  }
}
