// SPDX-License-Identifier: MIT
// Synthetic data only: the lattice is a made-up table that satisfies the
// structural rule, and the Mach-O images are built from scratch.
#if os(macOS)
  import Foundation
  import XCTest
  @testable import AuroraAppleInstallerTrustCore

  /// Synthetic lattices and Mach-O images for the lattice tests.
  enum SyntheticLattice {
    static func ends(bump: Bool = false) -> [UInt64] {
      var ends = (1...64).map { UInt64($0) }
      for index in 0..<36 { ends.append(64 + UInt64(((index + 1) * 257 + 35) / 36)) }
      if bump { ends[70] += 1 }
      return ends
    }

    static func pack(_ ends: [UInt64]) -> Data {
      var data = Data()
      for end in ends { withUnsafeBytes(of: end.littleEndian) { data.append(contentsOf: $0) } }
      return data
    }

    /// 1 to 64, then 36 evenly widening ends up to 321. Not macOS's table.
    static let table = pack(ends())
    /// A second valid table, different from `table`.
    static let other = pack(ends(bump: true))

    static func padded(_ table: Data, before: Int = 24, after: Int = 40) -> Data {
      Data(repeating: 0x11, count: before) + table + Data(repeating: 0x22, count: after)
    }

    /// Little-endian Mach-O fields, appended in order.
    private struct Writer {
      var data = Data()
      mutating func int<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
      }
      mutating func name(_ text: String) {
        let bytes = Array(text.utf8)
        data.append(contentsOf: bytes + [UInt8](repeating: 0, count: 16 - bytes.count))
      }
    }

    private static func section(
      _ sect: String, address: UInt64, size: Int, offset: Int, flags: UInt32 = 0
    ) -> Data {
      var w = Writer()
      w.name(sect)
      w.name("__TEXT")
      w.int(address)
      w.int(UInt64(size))
      w.int(UInt32(offset))
      w.int(UInt32(3))
      w.int(UInt32(0))
      w.int(UInt32(0))
      w.int(flags)
      for _ in 0..<3 { w.int(UInt32(0)) }
      return w.data
    }

    /// A 64-bit Mach-O image whose __TEXT holds __text, then `constSections`
    /// __const sections with `const`.
    static func thin(
      _ const: Data, text: Data = Data(repeating: 0, count: 64), cpu: Int32 = 0x0100_000C,
      skew: UInt64 = 0, constSections: Int = 1, constFlags: UInt32 = 0
    ) -> Data {
      let base = 0x1000
      var body = text
      body.append(Data(repeating: 0, count: (16 - text.count % 16) % 16))
      var sections = section(
        "__text", address: 0x1_0000_0000 + UInt64(base), size: text.count, offset: base)
      for _ in 0..<constSections {
        let offset = base + body.count
        sections.append(
          section(
            "__const", address: 0x1_0000_0000 + UInt64(offset) + skew, size: const.count,
            offset: offset, flags: constFlags))
        body.append(const)
        body.append(Data(repeating: 0, count: (16 - const.count % 16) % 16))
      }
      let count = 1 + constSections
      var segment = Writer()
      segment.int(UInt32(0x19))
      segment.int(UInt32(72 + 80 * count))
      segment.name("__TEXT")
      segment.int(UInt64(0x1_0000_0000))
      segment.int(UInt64(base + body.count))
      segment.int(UInt64(0))
      segment.int(UInt64(base + body.count))
      segment.int(Int32(5))
      segment.int(Int32(5))
      segment.int(UInt32(count))
      segment.int(UInt32(0))
      var image = Writer()
      image.int(UInt32(0xFEED_FACF))
      image.int(cpu)
      image.int(Int32(2))
      image.int(UInt32(6))
      image.int(UInt32(1))
      image.int(UInt32(segment.data.count + sections.count))
      image.int(UInt32(0))
      image.int(UInt32(0))
      var out = image.data
      out.append(segment.data)
      out.append(sections)
      out.append(Data(repeating: 0, count: base - out.count))
      out.append(body)
      return out
    }

    /// A universal file holding `images`, each slice 16 KiB aligned.
    static func fat(_ images: [Data]) -> Data {
      func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
      let align = 0x4000
      var table = be(0xCAFE_BABE) + be(UInt32(images.count))
      var offsets = [Int]()
      var offset = align
      for image in images {
        offsets.append(offset)
        offset = (offset + image.count + align - 1) / align * align
      }
      for (image, offset) in zip(images, offsets) {
        for field in [0x0100_000C, 2, UInt32(offset), UInt32(image.count), 14] {
          table.append(be(field))
        }
      }
      var out = table + Data(repeating: 0, count: align - table.count)
      for (image, offset) in zip(images, offsets) {
        out += Data(repeating: 0, count: offset - out.count)
        out += image
      }
      return out
    }

    /// The component the native collector reads, with `table` in two slices.
    static var component: Data { fat([thin(padded(table)), thin(padded(table))]) }
  }

  final class NativeLSM2LatticeTests: XCTestCase {
    typealias Lattice = NativeLSM2Lattice
    typealias S = SyntheticLattice

    func testTheRule() {
      XCTAssertTrue(Lattice.valid(S.table))
      XCTAssertTrue(Lattice.valid(S.other))
      XCTAssertFalse(Lattice.valid(S.table.prefix(792)))
      XCTAssertFalse(Lattice.valid(S.table + S.table.suffix(8)))
      var ends = S.ends()
      ends[99] = 320
      XCTAssertFalse(Lattice.valid(S.pack(ends)))
      ends[99] = 322
      XCTAssertFalse(Lattice.valid(S.pack(ends)))
      ends = S.ends()
      ends[70] = ends[69]
      XCTAssertFalse(Lattice.valid(S.pack(ends)))
      ends = S.ends()
      ends[10] = 12
      XCTAssertFalse(Lattice.valid(S.pack(ends)))
      XCTAssertFalse(Lattice.valid(Data(repeating: 0, count: 800)))
    }

    func testThinAndUniversalImages() throws {
      XCTAssertEqual(try Lattice.extract(S.thin(S.padded(S.table))), S.table)
      XCTAssertEqual(try Lattice.extract(S.component), S.table)
      let three = S.fat([
        S.thin(S.padded(S.table)), S.thin(S.padded(S.table, before: 8, after: 0)),
        S.thin(S.padded(S.table)),
      ])
      XCTAssertEqual(try Lattice.extract(three), S.table)
    }

    func testMissingAmbiguousOrDisagreeingFails() {
      XCTAssertThrowsError(try Lattice.extract(S.thin(Data(repeating: 0x11, count: 2048)))) {
        XCTAssertEqual($0 as? Lattice.Failure, .candidates(slice: 0, found: 0))
      }
      XCTAssertThrowsError(
        try Lattice.extract(S.thin(S.padded(S.table) + S.padded(S.other)))
      ) { XCTAssertEqual($0 as? Lattice.Failure, .candidates(slice: 0, found: 2)) }
      XCTAssertThrowsError(
        try Lattice.extract(
          S.fat([S.thin(S.padded(S.table)), S.thin(Data(repeating: 0x11, count: 2048))]))
      ) { XCTAssertEqual($0 as? Lattice.Failure, .candidates(slice: 1, found: 0)) }
      XCTAssertThrowsError(
        try Lattice.extract(S.fat([S.thin(S.padded(S.table)), S.thin(S.padded(S.other))]))
      ) { XCTAssertEqual($0 as? Lattice.Failure, .slicesDisagree) }
    }

    func testOnlyAlignedTextConstCounts() {
      for image in [
        S.thin(S.padded(S.table, before: 20)),
        S.thin(S.padded(S.table), skew: 4),
        S.thin(Data(repeating: 0x11, count: 64), text: S.padded(S.table)),
        S.thin(Data(repeating: 0x11, count: 24) + S.table.prefix(792)),
      ] {
        XCTAssertThrowsError(try Lattice.extract(image)) {
          XCTAssertEqual($0 as? Lattice.Failure, .candidates(slice: 0, found: 0))
        }
      }
    }

    func testMalformedImagesFail() {
      let good = S.thin(S.padded(S.table))
      var broken = good
      broken.replaceSubrange(20..<24, with: Data([0x10, 0x27, 0, 0]))
      for image in [
        Data(), Data([0xCF, 0xFA, 0xED, 0xFE]), good.prefix(200),
        Data("\u{7f}ELF".utf8) + good.dropFirst(4), S.fat([good]).prefix(16), broken,
        S.thin(S.padded(S.table), constSections: 2),
        S.thin(S.padded(S.table), constFlags: 0x1),
      ] {
        XCTAssertThrowsError(try Lattice.extract(image)) {
          guard case .malformed = $0 as? Lattice.Failure else {
            return XCTFail("unexpected \($0)")
          }
        }
      }
    }
  }
#endif
