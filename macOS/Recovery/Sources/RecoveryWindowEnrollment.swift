import Foundation

/// Utilities → Enroll Expanded Code Window: enrolls an installed system's Stage 1
/// padded, chainloading `AuraStage1Format.confinedStage2Path`. It writes only a
/// temporary copy of the object and the boot object kmutil stores. Boot policy, the
/// startup partition, firmware, recovery records and boot arguments stay as they are.
enum RecoveryWindowEnrollment {
  enum Refusal: Error, LocalizedError, Equatable {
    case notInstalled, notMachO, noMachOStage1, otherPartition, noConfinedStage2

    var errorDescription: String? {
      switch self {
      case .notInstalled:
        return "Finish installing Aurora before enrolling the expanded code window."
      case .notMachO:
        return "Only Macs with an M4-generation chip or later use the expanded code window."
      case .noMachOStage1:
        return
          "This installation's recovery files have no Mach-O startup software. Nothing was changed."
      case .otherPartition:
        return
          "This installation's recovery files name a different startup partition. Nothing was changed."
      case .noConfinedStage2:
        return
          "This system's startup partition has no \(AuraStage1Format.confinedStage2Path). Start Aurora Linux, install its updates, then try again. Nothing was changed."
      }
    }
  }

  /// What can be answered from this Mac and the installation's own records.
  static func check(
    chipID: UInt64?, bootMode: AuraBootMode, installed: Bool, hasMachOStage1: Bool,
    hasStartupPartition: Bool, hasConfinedStage2: Bool
  ) throws {
    guard installed else { throw Refusal.notInstalled }
    guard let chipID, AuraStage1Format.usesMachO(chipID: chipID) else { throw Refusal.notMachO }
    guard bootMode == .macho, hasMachOStage1 else { throw Refusal.noMachOStage1 }
    guard hasStartupPartition else { throw Refusal.otherPartition }
    guard hasConfinedStage2 else { throw Refusal.noConfinedStage2 }
  }

  /// `object` is the saved Stage 1, whichever path it was filled with. It must
  /// name this installation's startup partition.
  static func stage1(_ object: Data, espUUID: String) throws -> Data {
    guard try Stage1Configuration.read(object).espUUID == espUUID.lowercased() else {
      throw Refusal.otherPartition
    }
    return try Stage1Configuration.retargeted(
      object, stage2Path: AuraStage1Format.confinedStage2Path)
  }

  /// Commands and files are injected so the order can be tested without kmutil.
  static func run(
    admit: () throws -> Void, stage: () throws -> Void, enroll: () throws -> Void,
    cleanUp: () -> Void
  ) throws {
    try admit()
    defer { cleanUp() }
    try stage()
    try enroll()
  }
}
