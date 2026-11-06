import Foundation

/// Utilities → Enroll Expanded Code Window: enrolls an installed system's Stage 1
/// padded, chainloading `AuraStage1Format.confinedStage2Path`, then moves that
/// installation's records to match. The startup partition, firmware and boot
/// arguments stay as they are; enrolling changes the boot policy as any
/// enrollment does. A journal lets an interrupted run finish.
enum RecoveryWindowEnrollment {
  enum Refusal: Error, LocalizedError, Equatable {
    case notInstalled, notMachO, noMachOStage1, otherPartition, noConfinedStage2
    case confinedStage2TooLarge

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
      case .confinedStage2TooLarge:
        return
          "\(AuraStage1Format.confinedStage2Path) on this system's startup partition is larger than \(ExecuteWindow.auraSlot >> 20) MiB and could not load. Nothing was changed."
      }
    }
  }

  /// What can be answered from this Mac and the installation's own records.
  static func check(
    chipID: UInt64?, bootMode: AuraBootMode, installed: Bool, hasMachOStage1: Bool,
    hasStartupPartition: Bool, confinedStage2Bytes: UInt64?
  ) throws {
    guard installed else { throw Refusal.notInstalled }
    guard let chipID, AuraStage1Format.usesMachO(chipID: chipID) else { throw Refusal.notMachO }
    guard bootMode == .macho, hasMachOStage1 else { throw Refusal.noMachOStage1 }
    guard hasStartupPartition else { throw Refusal.otherPartition }
    guard let confinedStage2Bytes else { throw Refusal.noConfinedStage2 }
    guard confinedStage2Bytes <= ExecuteWindow.auraSlot else {
      throw Refusal.confinedStage2TooLarge
    }
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

  /// `enrolled` means kmutil succeeded and only the records are left to move.
  enum Phase: String, Codable {
    case prepared, enrollmentRequested, enrolled
  }

  struct Journal: Codable, Equatable {
    let operation: String
    let systemUUID: String
    let groupUUID: String
    let espUUID: String
    var stage1SHA256: String
    var stage2SHA256: String
    var phase: Phase

    func validate(system: String, group: String, esp: String) throws {
      guard operation.hasPrefix("window-"),
        UUID(uuidString: String(operation.dropFirst("window-".count))) != nil,
        systemUUID == system, groupUUID == group, espUUID == esp
      else { throw RecoveryWindowRecordError("The interrupted enrollment belongs elsewhere.") }
    }
  }

  /// Commands and files are injected so the order can be tested without kmutil.
  /// A refusal while staging has changed nothing. A failure from `enroll` is
  /// ambiguous, so its journal stays and the next run enrolls again.
  static func run(
    phase: Phase, persist: (Phase) throws -> Void, stage: () throws -> Void,
    enroll: () throws -> Void, record: () throws -> Void, finish: () throws -> Void
  ) throws {
    if phase != .enrolled {
      try stage()
      try persist(.enrollmentRequested)
      try enroll()
      try persist(.enrolled)
    }
    try record()
    try finish()
  }

  /// The files that say which Stage 2 an installation loads.
  struct Records {
    let configuration: URL
    let manifest: URL
    let savedStage1: URL
    let savedStage2: URL
    let receipt: URL

    var files: [URL] { [configuration, manifest, savedStage1, savedStage2, receipt] }
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RecoveryWindowRecordError("An installation record is not readable.")
    }
    return value
  }

  private static func record(_ bytes: Data) -> [String: Any] {
    ["sha256": RecoveryDigest.sha256(bytes), "bytes": bytes.count]
  }

  static func updatedConfiguration(_ data: Data) throws -> Data {
    var value = try object(data)
    guard value["bootMode"] as? String == AuraBootMode.macho.rawValue else {
      throw RecoveryWindowRecordError("This installation does not use the Mach-O startup software.")
    }
    value["stage2Path"] = AuraStage1Format.confinedStage2Path
    let result = try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    _ = try InstallConfiguration.decode(result)
    return result
  }

  static func updatedManifest(_ data: Data, stage1: Data, stage2: Data) throws -> Data {
    var value = try object(data)
    guard var files = value["files"] as? [String: Any] else {
      throw RecoveryWindowRecordError("The recovery payload manifest is invalid.")
    }
    files[AuraBootMode.macho.stage1Path] = record(stage1)
    files[AuraBootMode.macho.stage2Path] = record(stage2)
    value["files"] = files
    value["defaultMode"] = AuraBootMode.macho.rawValue
    value["modes"] = [
      AuraBootMode.macho.rawValue: ["espPath": AuraStage1Format.confinedStage2Path]
    ]
    value.removeValue(forKey: "nestedVirtualization")
    return try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  static func updatedReceipt(_ data: Data, stage1: Data, stage2: Data) throws -> Data {
    var value = try object(data)
    value["stage2Path"] = AuraStage1Format.confinedStage2Path
    value["stage1SHA256"] = RecoveryDigest.sha256(stage1)
    value["stage2SHA256"] = RecoveryDigest.sha256(stage2)
    value["executeWindowSize"] = ExecuteWindow.size
    value.removeValue(forKey: "nestedVirtualization")
    return try JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  }

  /// Moves every record in one step. An interrupted earlier attempt is rolled
  /// back first, and a failure here rolls back, so a reader never sees a mix.
  static func commit(
    _ records: Records, stage1: Data, stage2: Data, rollback directory: URL
  ) throws {
    let fm = FileManager.default
    let transaction: RecoveryFileTransaction
    if fm.fileExists(atPath: directory.appendingPathComponent("files.json").path) {
      transaction = try .resume(directory: directory, files: records.files)
      try transaction.restore()
    } else {
      if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
      transaction = try RecoveryFileTransaction(directory: directory, files: records.files)
    }
    do {
      let configuration = try updatedConfiguration(Data(contentsOf: records.configuration))
      let manifest = try updatedManifest(
        Data(contentsOf: records.manifest), stage1: stage1, stage2: stage2)
      let receipt = try updatedReceipt(
        Data(contentsOf: records.receipt), stage1: stage1, stage2: stage2)
      try RecoveryFileTransaction.write(stage1, to: records.savedStage1)
      try RecoveryFileTransaction.write(stage2, to: records.savedStage2)
      try RecoveryFileTransaction.write(manifest, to: records.manifest)
      try RecoveryFileTransaction.write(configuration, to: records.configuration)
      try RecoveryFileTransaction.write(receipt, to: records.receipt)
      try transaction.commit()
    } catch {
      try? transaction.restore()
      throw error
    }
  }
}

struct RecoveryWindowRecordError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
