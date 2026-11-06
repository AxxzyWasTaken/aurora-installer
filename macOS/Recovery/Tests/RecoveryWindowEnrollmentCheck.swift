import Foundation

@main struct RecoveryWindowEnrollmentCheck {
  typealias Refusal = RecoveryWindowEnrollment.Refusal

  static func refusal(
    chip: UInt64? = 0x8140, mode: AuraBootMode = .macho, installed: Bool = true,
    object: Bool = true, partition: Bool = true, stage2: Bool = true
  ) -> Refusal? {
    do {
      try RecoveryWindowEnrollment.check(
        chipID: chip, bootMode: mode, installed: installed, hasMachOStage1: object,
        hasStartupPartition: partition, hasConfinedStage2: stage2)
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

  static func main() throws {
    for chip: UInt64 in [0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050] {
      precondition(refusal(chip: chip) == nil, String(chip, radix: 16))
    }
    // It refuses a system that has not taken the package update carrying this file.
    precondition(refusal(stage2: false) == .noConfinedStage2)
    let message = Refusal.noConfinedStage2.errorDescription ?? ""
    precondition(message.contains("m1n1/boot-ctxr.bin") && message.contains("install its updates"))
    precondition(message.contains("Nothing was changed"))
    precondition(refusal(installed: false) == .notInstalled)
    for chip: UInt64? in [nil, 0x8103, 0x8122, 0x6032] {
      precondition(refusal(chip: chip) == .notMachO)
    }
    precondition(refusal(mode: .raw) == .noMachOStage1)
    precondition(refusal(object: false) == .noMachOStage1)
    precondition(refusal(partition: false) == .otherPartition)

    // A refusal comes before staging and enrolling, and nothing is left to clean up.
    for fails in [true, false] {
      var steps: [String] = []
      do {
        try RecoveryWindowEnrollment.run(
          admit: {
            steps.append("admit")
            if fails { throw Refusal.noConfinedStage2 }
          },
          stage: { steps.append("stage") }, enroll: { steps.append("enroll") },
          cleanUp: { steps.append("clean") })
        precondition(!fails)
      } catch {
        precondition(fails && error as? Refusal == .noConfinedStage2)
      }
      precondition(steps == (fails ? ["admit"] : ["admit", "stage", "enroll", "clean"]))
    }
    // A failed enrollment still removes its temporary copy.
    var cleaned = false
    do {
      try RecoveryWindowEnrollment.run(
        admit: {}, stage: {}, enroll: { throw Refusal.otherPartition }, cleanUp: { cleaned = true })
      preconditionFailure("a failed enrollment reported success")
    } catch {
      precondition(cleaned)
    }

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
      "PASS window enrollment: refuses without m1n1/boot-ctxr.bin before anything else, on M1 to M3, without its object or partition; retargets only the Stage 2 path; removes its temporary copy"
    )
  }
}
