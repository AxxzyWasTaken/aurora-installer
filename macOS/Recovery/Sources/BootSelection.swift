import Foundation

enum AuraBootMode: String, Codable {
  case raw
  case macho

  var stage1Path: String {
    self == .raw ? "raw/aura-raw.bin" : "macho/aura-boot.macho"
  }

  /// The Mach-O Stage 1 carries the raw image unchanged, so both chainload
  /// the same Stage 2 from the startup partition.
  var stage2Path: String { "raw/boot.bin" }

  /// `compress` stores a Mach-O payload with LZFSE in Preboot, as the stock
  /// kernelcache is stored, and has no meaning for a raw image.
  func enrollmentArguments(stage1: String, volume: String, compress: Bool = false) -> [String] {
    var arguments = ["configure-boot", "-c", stage1, "-v", volume]
    if self == .raw {
      arguments += ["--raw", "--entry-point", "2048", "--lowest-virtual-address", "0"]
    } else if compress {
      arguments.append("--compress")
    }
    return arguments
  }
}

struct BootSelection: Codable {
  let mode: AuraBootMode
  let nestedVirtualization: Bool
  /// Enroll the Mach-O object padded for a larger code-execute window.
  let expandedExecuteWindow: Bool

  init(
    machoEnabled: Bool = false, nestedVirtualization: Bool = false,
    expandedExecuteWindow: Bool = false
  ) {
    mode = machoEnabled ? .macho : .raw
    self.nestedVirtualization = machoEnabled && nestedVirtualization
    self.expandedExecuteWindow = machoEnabled && expandedExecuteWindow
  }
}

enum RecoveryBootPolicy {
  static func authorizationArguments(
    groupUUID: String, allowCustomBootArguments: Bool = false
  ) -> [String] {
    [allowCustomBootArguments ? "-nca" : "-nc", "-v", groupUUID]
  }
}

/// aura's Stage 2 reads `chosen.aura,nv2=0|1` from the configuration lines
/// after its payloads, and the last one wins. update-m1n1 writes them from
/// /etc/m1n1.conf; Recovery appends its own and replaces only one it appended.
enum NestedVirtualizationSetting {
  static let lines = ["chosen.aura,nv2=0\n", "chosen.aura,nv2=1\n"].map { Data($0.utf8) }

  static func stage2(_ stage2: Data, enabled: Bool) -> Data {
    var result = Data(stage2)
    while let line = lines.first(where: {
      result.count > $0.count && result.suffix($0.count) == $0
    }), result[result.count - line.count - 1] == 0x0A {
      result.removeLast(line.count)
    }
    result.append(lines[enabled ? 1 : 0])
    return result
  }
}
