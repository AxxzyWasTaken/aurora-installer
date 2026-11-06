import Foundation

struct AccountSetupFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

@main struct RecoveryWindowEnrollmentCheck {
  typealias Refusal = RecoveryWindowEnrollment.Refusal
  enum Fault: Error { case injected }

  static func refusal(
    chip: UInt64? = 0x8140, mode: AuraBootMode = .macho, installed: Bool = true,
    object: Bool = true, partition: Bool = true, stage2: UInt64? = 4 << 20
  ) -> Refusal? {
    do {
      try RecoveryWindowEnrollment.check(
        chipID: chip, bootMode: mode, installed: installed, hasMachOStage1: object,
        hasStartupPartition: partition, confinedStage2Bytes: stage2)
      return nil
    } catch { return error as? Refusal }
  }

  /// A filled Stage 1 block as aura's tools/fill_stage1_config.py writes it.
  static func filled(uuid: String, path: String, crc: UInt32) -> Data {
    func le(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    let encoded = Array((";" + path).utf8)
    var image = Data("code".utf8) + Data("AURORA-S1-CFG01\0".utf8)
    image += le(1) + le(5000) + Array(uuid.utf8) + [UInt8](repeating: 0, count: 4)
    image += encoded + [UInt8](repeating: 0, count: 192 - encoded.count) + le(crc)
    return image + Data("tail".utf8)
  }

  static func checkRefusals() {
    for chip: UInt64 in [0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050] {
      precondition(refusal(chip: chip) == nil, String(chip, radix: 16))
    }
    // It refuses a system that has not taken the package update carrying this file.
    precondition(refusal(stage2: nil) == .noConfinedStage2)
    let message = Refusal.noConfinedStage2.errorDescription ?? ""
    precondition(message.contains("m1n1/boot-ctxr.bin") && message.contains("install its updates"))
    precondition(message.contains("Nothing was changed"))
    // A Stage 2 that can't fit aura's slot can't load.
    precondition(refusal(stage2: 16 << 20) == nil)
    precondition(refusal(stage2: (16 << 20) + 1) == .confinedStage2TooLarge)
    precondition(refusal(installed: false) == .notInstalled)
    for chip: UInt64? in [nil, 0x8103, 0x8122, 0x6032] {
      precondition(refusal(chip: chip) == .notMachO)
    }
    precondition(refusal(mode: .raw) == .noMachOStage1)
    precondition(refusal(object: false) == .noMachOStage1)
    precondition(refusal(partition: false) == .otherPartition)
  }

  static func checkOrder() throws {
    func steps(
      from phase: RecoveryWindowEnrollment.Phase, failing: String? = nil
    ) -> (steps: [String], failed: Bool) {
      var steps: [String] = []
      func step(_ name: String) throws {
        steps.append(name)
        if name == failing { throw Fault.injected }
      }
      do {
        try RecoveryWindowEnrollment.run(
          phase: phase, persist: { try step($0.rawValue) }, stage: { try step("stage") },
          enroll: { try step("enroll") }, record: { try step("record") },
          finish: { try step("finish") })
        return (steps, false)
      } catch { return (steps, true) }
    }
    let whole = ["stage", "enrollmentRequested", "enroll", "enrolled", "record", "finish"]
    precondition(steps(from: .prepared).steps == whole)
    // A retry after an ambiguous kmutil result enrolls again.
    precondition(steps(from: .enrollmentRequested).steps == whole)
    // Once kmutil finished, only the records are left: no second enrollment, no password.
    precondition(steps(from: .enrolled).steps == ["record", "finish"])
    // Progress is durable before kmutil runs and straight after it succeeds.
    for failing in whole {
      let run = steps(from: .prepared, failing: failing)
      precondition(run.failed && run.steps.last == failing)
      precondition(run.steps == Array(whole.prefix(whole.firstIndex(of: failing)! + 1)))
    }
    let journal = RecoveryWindowEnrollment.Journal(
      operation: "window-" + UUID().uuidString, systemUUID: "system", groupUUID: "group",
      espUUID: "esp", stage1SHA256: "one", stage2SHA256: "two", phase: .enrollmentRequested)
    let decoded = try JSONDecoder().decode(
      RecoveryWindowEnrollment.Journal.self, from: JSONEncoder().encode(journal))
    precondition(decoded == journal)
    try journal.validate(system: "system", group: "group", esp: "esp")
    for (system, group, esp) in [
      ("x", "group", "esp"), ("system", "x", "esp"), ("system", "group", "x"),
    ] {
      do {
        try journal.validate(system: system, group: group, esp: esp)
        preconditionFailure("accepted another installation's journal")
      } catch {}
    }
  }

  static func checkRecords() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(
      "window-records-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let uuid = "ABCDABCD-0000-4000-8000-00000000000"
    let config: [String: Any] = [
      "schema": 2, "volumeName": "Aurora", "systemUUID": uuid + "1", "groupUUID": uuid + "2",
      "prebootUUID": uuid + "3", "espUUID": uuid + "4", "bootMode": "macho",
      "stage2Path": "m1n1/boot.bin", "bootstrap": NSNull(),
    ]
    let oldStage1 = Data("old stage 1".utf8)
    let oldStage2 = Data("old stage 2".utf8)
    func entry(_ bytes: Data) -> [String: Any] {
      ["sha256": RecoveryDigest.sha256(bytes), "bytes": bytes.count]
    }
    let manifest: [String: Any] = [
      "schema": 2, "defaultMode": "macho", "nestedVirtualization": false,
      "modes": ["raw": ["espPath": "m1n1/boot.bin"], "macho": ["espPath": "m1n1/boot.bin"]],
      "vendorFirmware": ["vendorfw/firmware.tar"],
      "files": [
        "macho/aura-boot.macho": entry(oldStage1), "raw/boot.bin": entry(oldStage2),
        "raw/aura-raw.bin": entry(Data("raw".utf8)),
      ],
    ]
    let receipt: [String: Any] = [
      "schema": 1, "mode": "macho", "stage2Path": "m1n1/boot.bin", "status": "installed",
      "stage1SHA256": RecoveryDigest.sha256(oldStage1),
      "stage2SHA256": RecoveryDigest.sha256(oldStage2), "nestedVirtualization": false,
      "recoveryAccountDeferred": true,
    ]
    let records = RecoveryWindowEnrollment.Records(
      configuration: root.appendingPathComponent("install-config.json"),
      manifest: root.appendingPathComponent("manifest.json"),
      savedStage1: root.appendingPathComponent("aura-boot.macho"),
      savedStage2: root.appendingPathComponent("boot.bin"),
      receipt: root.appendingPathComponent("installation.json"))
    func reset() throws {
      try JSONSerialization.data(withJSONObject: config).write(to: records.configuration)
      try JSONSerialization.data(withJSONObject: manifest).write(to: records.manifest)
      try oldStage1.write(to: records.savedStage1)
      try oldStage2.write(to: records.savedStage2)
      try JSONSerialization.data(withJSONObject: receipt).write(to: records.receipt)
    }
    try reset()
    let before = try records.files.map { try Data(contentsOf: $0) }
    let stage1 = Data("new stage 1".utf8)
    let stage2 = Data("new confined stage 2".utf8)
    let rollback = root.appendingPathComponent("rollback")
    try RecoveryWindowEnrollment.commit(records, stage1: stage1, stage2: stage2, rollback: rollback)

    func json(_ url: URL) throws -> [String: Any] {
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    func checkMoved() throws {
      let newConfig = try InstallConfiguration.decode(Data(contentsOf: records.configuration))
      precondition(newConfig.stage2Path == "m1n1/boot-ctxr.bin" && newConfig.bootMode == "macho")
      let newManifest = try json(records.manifest)
      let modes = newManifest["modes"] as! [String: [String: String]]
      precondition(modes == ["macho": ["espPath": "m1n1/boot-ctxr.bin"]])
      precondition(newManifest["nestedVirtualization"] == nil)
      let files = newManifest["files"] as! [String: [String: Any]]
      precondition(
        files["macho/aura-boot.macho"]?["sha256"] as? String == RecoveryDigest.sha256(stage1))
      precondition(files["raw/boot.bin"]?["sha256"] as? String == RecoveryDigest.sha256(stage2))
      precondition(files["raw/boot.bin"]?["bytes"] as? Int == stage2.count)
      precondition(files["raw/aura-raw.bin"] != nil, "the other saved files are kept")
      precondition(newManifest["vendorFirmware"] as? [String] == ["vendorfw/firmware.tar"])
      let savedStage1 = try Data(contentsOf: records.savedStage1)
      let savedStage2 = try Data(contentsOf: records.savedStage2)
      precondition(savedStage1 == stage1 && savedStage2 == stage2)
      let newReceipt = try json(records.receipt)
      precondition(newReceipt["stage2Path"] as? String == "m1n1/boot-ctxr.bin")
      precondition(newReceipt["stage1SHA256"] as? String == RecoveryDigest.sha256(stage1))
      precondition(newReceipt["stage2SHA256"] as? String == RecoveryDigest.sha256(stage2))
      precondition(newReceipt["executeWindowSize"] as? UInt64 == 128 << 20)
      precondition(newReceipt["status"] as? String == "installed")
      precondition(newReceipt["recoveryAccountDeferred"] as? Bool == true, "other fields are kept")
      precondition(newReceipt["nestedVirtualization"] == nil)
    }
    try checkMoved()

    // A crash part way through: the next attempt rolls back, then moves everything.
    try fm.removeItem(at: rollback)
    try reset()
    _ = try RecoveryFileTransaction(directory: rollback, files: records.files)
    try Data("half written".utf8).write(to: records.manifest)
    try stage1.write(to: records.savedStage1)
    try RecoveryWindowEnrollment.commit(records, stage1: stage1, stage2: stage2, rollback: rollback)
    try checkMoved()

    // A snapshot that never finished wrote nothing, and doesn't block the next attempt.
    try fm.removeItem(at: rollback)
    try reset()
    try fm.createDirectory(at: rollback, withIntermediateDirectories: false)
    try RecoveryWindowEnrollment.commit(records, stage1: stage1, stage2: stage2, rollback: rollback)
    try checkMoved()

    // A record it can't update leaves every file as it was, and can be retried.
    try fm.removeItem(at: rollback)
    try reset()
    try Data("not json".utf8).write(to: records.receipt)
    let broken = try records.files.map { try Data(contentsOf: $0) }
    do {
      try RecoveryWindowEnrollment.commit(
        records, stage1: stage1, stage2: stage2, rollback: rollback)
      preconditionFailure("moved the records past an unreadable receipt")
    } catch {}
    let afterFailure = try records.files.map { try Data(contentsOf: $0) }
    precondition(afterFailure == broken)
    precondition(before.count == broken.count)

    // Only a Mach-O installation can name the confined path.
    do {
      var raw = config
      raw["bootMode"] = "raw"
      _ = try RecoveryWindowEnrollment.updatedConfiguration(
        JSONSerialization.data(withJSONObject: raw))
      preconditionFailure("moved a raw installation to the confined Stage 2")
    } catch {}
  }

  static func main() throws {
    checkRefusals()
    try checkOrder()
    try checkRecords()

    // The saved object may name either path. It leaves here naming the confined one.
    let uuid = "3ce364b1-1de6-4418-a00d-5b2d95884ad7"
    let old = filled(uuid: uuid, path: "m1n1/boot.bin", crc: 0x3C0C_2E4E)
    let new = filled(uuid: uuid, path: "m1n1/boot-ctxr.bin", crc: 0x158D_6EE6)
    let retargeted = try RecoveryWindowEnrollment.stage1(old, espUUID: uuid.uppercased())
    precondition(retargeted == new)
    let unchanged = try RecoveryWindowEnrollment.stage1(new, espUUID: uuid)
    precondition(unchanged == new)
    do {
      _ = try RecoveryWindowEnrollment.stage1(old, espUUID: "21336113-1de6-4418-a00d-5b2d95884ad7")
      preconditionFailure("enrolled a Stage 1 that names another startup partition")
    } catch {
      precondition(error as? Refusal == .otherPartition)
    }
    print(
      "PASS window enrollment: refuses without m1n1/boot-ctxr.bin or when it can't load, on M1 to M3, without its object or partition; journal order and resume; records move in one step with a saved baseline and roll back; retargets only the Stage 2 path"
    )
  }
}
