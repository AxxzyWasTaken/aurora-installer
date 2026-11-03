import Foundation

@main struct MachOBootObjectCheck {
  static let base: UInt64 = 0xFFFF_FE00_0700_4000

  struct Segment {
    var name: String
    var offset: UInt64
    var size: UInt64
    var fileOffset: UInt64? = nil
  }

  static func object(
    _ segments: [Segment], entry: UInt64 = 0x10800, filetype: UInt32 = 12
  ) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
      withUnsafeBytes(of: value.littleEndian, Array.init)
    }
    var commands: [UInt8] = []
    for segment in segments {
      var name = Array(segment.name.utf8)
      name += [UInt8](repeating: 0, count: 16 - name.count)
      commands += le(UInt32(0x19)) + le(UInt32(72)) + name
      commands += le(base + segment.offset) + le(segment.size)
      commands += le(segment.fileOffset ?? segment.offset) + le(segment.size)
      commands += le(UInt32(1)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(0))
    }
    var registers = [UInt64](repeating: 0, count: 34)
    registers[32] = base + entry
    commands += le(UInt32(5)) + le(UInt32(16 + 34 * 8)) + le(UInt32(6)) + le(UInt32(0x44))
    for register in registers { commands += le(register) }
    var bytes = le(UInt32(0xFEED_FACF)) + le(UInt32(0x0100_000C)) + le(UInt32(0xC000_0002))
    bytes += le(filetype) + le(UInt32(segments.count + 1)) + le(UInt32(commands.count))
    bytes += le(UInt32(0)) + le(UInt32(0)) + commands
    let end = segments.map { $0.offset + $0.size }.max() ?? 0
    bytes += [UInt8](repeating: 0, count: Int(end) - bytes.count)
    return Data(bytes)
  }

  static let valid = [
    Segment(name: "__TEXT", offset: 0, size: 0x8000),
    Segment(name: "__PRELINK_TEXT", offset: 0x8000, size: 0x8000),
    Segment(name: "__TEXT_EXEC", offset: 0x10000, size: 0x430000),
    Segment(name: "__PRELINK_INFO", offset: 0x440000, size: 0x4000),
    Segment(name: "__DATA", offset: 0x444000, size: 0x4000),
    Segment(name: "__LINKEDIT", offset: 0x448000, size: 0x4000),
  ]

  static func rejects(_ data: Data, _ why: String) {
    do {
      try MachOBootObject.check(data)
      preconditionFailure("accepted: \(why)")
    } catch {}
  }

  static func main() throws {
    try MachOBootObject.check(object(valid))

    var boot = valid
    boot.insert(Segment(name: "__TEXT_BOOT_EXEC", offset: 0x440000, size: 0x4000), at: 3)
    boot[4].offset = 0x444000
    boot[5].offset = 0x448000
    boot[6].offset = 0x44c000
    rejects(object(boot), "a nonempty __TEXT_BOOT_EXEC starts SPTM")
    var empty = valid
    empty.insert(Segment(name: "__TEXT_BOOT_EXEC", offset: 0x440000, size: 0), at: 3)
    try MachOBootObject.check(object(empty))

    rejects(object(valid, filetype: 2), "not a fileset")
    rejects(object(valid.filter { $0.name != "__PRELINK_INFO" }), "kmutil requires __PRELINK_INFO")
    rejects(object(valid, entry: 0x8000), "entry outside __TEXT_EXEC")
    var moved = valid
    moved[2].fileOffset = 0x14000
    rejects(object(moved), "file offset differs from virtual offset")
    rejects(object(valid).prefix(0x20000), "segments past the end of the file")
    rejects(Data(count: 0x10000), "raw image")

    // Output of `kmutil inspect --show-mach-boot-properties` on macOS 26.6.2.
    let inspection = """
      Mach-O boot properties derived for boot kernel collection:
      {
          kclo : 18446741874803752960
          kcep : 18446741874803820544
          kcbf : 0
          kcbz : 0
          kcwf : 4456448
      }
      """
    precondition(MachOBootObject.bootExecSize(fromInspection: inspection) == 0)
    precondition(
      MachOBootObject.bootExecSize(
        fromInspection: inspection.replacingOccurrences(
          of: "kcbz : 0", with: "kcbz : 32768")) == 32768)
    precondition(MachOBootObject.bootExecSize(fromInspection: "no properties") == nil)

    // The installer fills the Stage 1 that the boot object carries in place.
    let raw = Data((0..<0x18000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) })
    var carrier = object(valid)
    carrier.replaceSubrange(0x10000..<(0x10000 + raw.count), with: raw)
    var filled = raw
    filled.replaceSubrange(0x9000..<0x9010, with: Data(repeating: 0xAB, count: 16))
    let result = try MachOBootObject.fill(carrier, raw: raw, filled: filled)
    precondition(result.count == carrier.count)
    precondition(result.subdata(in: 0x10000..<(0x10000 + raw.count)) == filled)
    precondition(result.prefix(0x10000) == carrier.prefix(0x10000))
    precondition(
      result.suffix(from: 0x10000 + raw.count) == carrier.suffix(from: 0x10000 + raw.count))
    func refusesFill(_ object: Data, raw: Data, filled: Data, _ why: String) {
      do {
        _ = try MachOBootObject.fill(object, raw: raw, filled: filled)
        preconditionFailure("filled: \(why)")
      } catch {}
    }
    var other = raw
    other[0x100] ^= 0xFF
    refusesFill(carrier, raw: other, filled: filled, "another Stage 1")
    refusesFill(carrier, raw: raw, filled: filled.prefix(raw.count - 1), "a different length")
    var trailing = carrier
    trailing[0x10000 + raw.count + 8] = 1
    refusesFill(trailing, raw: raw, filled: filled, "data after the Stage 1")
    refusesFill(object(valid, entry: 0x10000), raw: raw, filled: filled, "not its entry point")
    refusesFill(carrier, raw: Data(count: 0x430001), filled: Data(count: 0x430001), "too large")

    // M4 and later use the Mach-O Stage 1; every M1 to M3 chip keeps raw.
    for chip: UInt64 in [0x8132, 0x6040, 0x6041, 0x8140, 0x8142, 0x6050, 0x6051, 0x6052, 0x8150] {
      precondition(AuraStage1Format.usesMachO(chipID: chip), String(chip, radix: 16))
    }
    for chip: UInt64 in [
      0x8103, 0x6000, 0x6001, 0x6002, 0x8112, 0x6020, 0x6021, 0x6022, 0x8122, 0x6030, 0x6031,
      0x6032, 0x6034, 0, 0x8000, 0x7000, 0x9000,
    ] {
      precondition(!AuraStage1Format.usesMachO(chipID: chip), String(chip, radix: 16))
    }
    print(
      "PASS Mach-O boot object: no __TEXT_BOOT_EXEC, kmutil's required segments, linear file backing, entry in __TEXT_EXEC; kcbz from kmutil inspect; in-place Stage 1 fill; M4-and-later chip predicate"
    )
  }
}
