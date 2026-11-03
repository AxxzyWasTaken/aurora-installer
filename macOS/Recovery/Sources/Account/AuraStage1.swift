import Foundation

/// Which Stage 1 boot object a Mac enrolls.
public enum AuraStage1Format {
  /// M4-generation and later chips boot aura's Mach-O boot object: T8132
  /// (M4), T6040/T6041 (M4 Pro/Max), T8140 (A18 Pro), T8142 and T605x (M5)
  /// and whatever follows them. Apple numbers each generation upward, so M1 to
  /// M3 (T8103, T8112, T8122, T600x, T602x, T603x) stay below both bounds and
  /// keep the raw image.
  public static func usesMachO(chipID: UInt64) -> Bool {
    (0x8130...0x8FFF).contains(chipID) || (0x6040...0x6FFF).contains(chipID)
  }
}

/// Checks a Mach-O Stage 1 before kmutil enrolls it. kmutil records the size
/// of __TEXT_BOOT_EXEC as the boot policy's kcbz, and iBoot starts SPTM only
/// when kcbz is nonzero, so the object must not have that segment. Aura's
/// boot objects (aura tools/macho_boot_object.py) also keep every segment
/// fully file-backed at its virtual offset, which is how iBoot places them.
public enum MachOBootObject {
  public struct Invalid: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? {
      "The Mach-O startup software is invalid: \(reason)."
    }
  }

  struct Segment {
    let vmaddr: UInt64
    let vmsize: UInt64
    let fileoff: UInt64
    let filesize: UInt64
  }

  static let required = ["__TEXT", "__TEXT_EXEC", "__PRELINK_INFO", "__LINKEDIT"]
  /// The raw image's entry point: `--entry-point 2048` in raw mode.
  static let rawEntryOffset: UInt64 = 0x800

  public static func check(_ data: Data) throws {
    _ = try layout(data)
  }

  static func layout(_ data: Data) throws -> (segments: [String: Segment], entry: UInt64) {
    let bytes = [UInt8](data)
    func u32(_ offset: Int) throws -> UInt32 {
      guard offset >= 0, offset + 4 <= bytes.count else { throw Invalid(reason: "truncated") }
      return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
    func u64(_ offset: Int) throws -> UInt64 {
      UInt64(try u32(offset)) | UInt64(try u32(offset + 4)) << 32
    }
    guard try u32(0) == 0xFEED_FACF, try u32(4) == 0x0100_000C else {
      throw Invalid(reason: "not a 64-bit Arm Mach-O image")
    }
    guard try u32(12) == 12 else { throw Invalid(reason: "not a fileset boot object") }
    let count = Int(try u32(16))
    let size = Int(try u32(20))
    guard 32 + size <= bytes.count else { throw Invalid(reason: "load commands are truncated") }
    var segments: [String: Segment] = [:]
    var entry: UInt64?
    var offset = 32
    for _ in 0..<count {
      let command = try u32(offset)
      let length = Int(try u32(offset + 4))
      guard length >= 8, length % 8 == 0, offset + length <= 32 + size else {
        throw Invalid(reason: "malformed load command")
      }
      if command == 0x19 {  // LC_SEGMENT_64
        guard length >= 72 else { throw Invalid(reason: "malformed segment") }
        let name = String(
          decoding: bytes[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }, as: UTF8.self)
        guard segments[name] == nil else { throw Invalid(reason: "duplicate segment \(name)") }
        segments[name] = Segment(
          vmaddr: try u64(offset + 24), vmsize: try u64(offset + 32),
          fileoff: try u64(offset + 40), filesize: try u64(offset + 48))
      } else if command == 0x5 {  // LC_UNIXTHREAD
        guard length >= 16 + 34 * 8, try u32(offset + 8) == 6 else {
          throw Invalid(reason: "malformed entry thread")
        }
        entry = try u64(offset + 16 + 32 * 8)
      }
      offset += length
    }
    guard offset == 32 + size else { throw Invalid(reason: "load command sizes disagree") }
    if let boot = segments["__TEXT_BOOT_EXEC"], boot.vmsize != 0 || boot.filesize != 0 {
      throw Invalid(reason: "it has __TEXT_BOOT_EXEC, so iBoot would start SPTM")
    }
    for name in required where segments[name] == nil {
      throw Invalid(reason: "it has no \(name) segment")
    }
    let base = segments["__TEXT"]!.vmaddr
    guard segments["__TEXT"]!.fileoff == 0 else {
      throw Invalid(reason: "__TEXT is not at offset 0")
    }
    for (name, segment) in segments where segment.vmsize != 0 {
      guard segment.vmaddr >= base, segment.fileoff == segment.vmaddr - base,
        segment.filesize == segment.vmsize,
        segment.fileoff <= UInt64(bytes.count),
        segment.filesize <= UInt64(bytes.count) - segment.fileoff
      else { throw Invalid(reason: "\(name) is not file-backed at its virtual offset") }
    }
    let code = segments["__TEXT_EXEC"]!
    guard let entry, entry >= code.vmaddr, entry - code.vmaddr < code.vmsize else {
      throw Invalid(reason: "its entry point is outside __TEXT_EXEC")
    }
    return (segments, entry)
  }

  /// Returns `object` with the Stage 1 configuration that `filled` carries.
  /// `object` must be aura's boot object for `raw`: the raw image unchanged at
  /// the start of __TEXT_EXEC, then only zero padding, entered at the raw
  /// image's own entry point. `filled` is `raw` with its configuration block
  /// filled, so the result is that boot object made from `filled`.
  public static func fill(_ object: Data, raw: Data, filled: Data) throws -> Data {
    let object = Data(object)
    let (segments, entry) = try layout(object)
    let code = segments["__TEXT_EXEC"]!
    guard !raw.isEmpty, filled.count == raw.count, UInt64(raw.count) <= code.filesize else {
      throw Invalid(reason: "it does not carry this Stage 1")
    }
    guard entry == code.vmaddr + rawEntryOffset else {
      throw Invalid(reason: "it does not enter this Stage 1 at its entry point")
    }
    let start = Int(code.fileoff)
    let end = start + raw.count
    guard object.subdata(in: start..<end) == raw,
      object.subdata(in: end..<(start + Int(code.filesize))).allSatisfy({ $0 == 0 })
    else { throw Invalid(reason: "it does not carry this Stage 1") }
    var result = object
    result.replaceSubrange(start..<end, with: filled)
    return result
  }

  /// kmutil's own derivation, printed by `kmutil inspect --show-mach-boot-properties`.
  public static func bootExecSize(fromInspection output: String) -> UInt64? {
    for line in output.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.count == 2, parts[0] == "kcbz" { return UInt64(parts[1]) }
    }
    return nil
  }
}
