import CryptoKit
import Foundation
import XCTest

@testable import AuroraFirmware

final class UpdateArchiveImageTests: XCTestCase {
  /// One XZ stream with no integrity check, as Apple's PBZX chunks have,
  /// whose output is `xzInput`. The same bytes are in
  /// `test/native-update-archive-vectors.py`.
  static let xzChunk = Data(
    hex:
      "fd377a585a000000ff12d9410200210116000000742fe5a3e00fff003f5d00209d4a4711"
      + "8d8debbaf4130889b5a88123f5047ee1cb7372b1a07afee112c76903843aef3d5323a596"
      + "b3a291464f8da184648ddeae636f1157c4a6a9d57c000000000153802000000028b19b58"
      + "a8000afc020000000000595a")
  static let xzInput = Data(
    String(repeating: "Aurora update archive recovery chunk ", count: 200).utf8
  ).prefix(4096)

  struct Chunk {
    var output: Int
    var stored: Data
  }

  /// A BXDIFF50 member whose output is `image`, made of `chunks`.
  static func member(
    image: Data, chunks: [Chunk], chunkBytes: Int = 4096, control: Int = 0,
    outputBytes: Int? = nil, sha1: Data? = nil
  ) -> Data {
    var stream = Data("pbzx".utf8) + big(chunkBytes)
    for chunk in chunks { stream += big(chunk.output) + big(chunk.stored.count) + chunk.stored }
    return Data("BXDIFF50".utf8) + Data(count: 8) + little(outputBytes ?? image.count)
      + little(control) + little(stream.count) + (sha1 ?? Data(Insecure.SHA1.hash(data: image)))
      + stream
  }

  static func big(_ value: Int) -> Data {
    Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(value) >> ($0 * 8)) })
  }
  static func little(_ value: Int) -> Data {
    Data((0..<8).map { UInt8(truncatingIfNeeded: UInt64(value) >> ($0 * 8)) })
  }

  /// The image `wholeImage` decodes to, and its member.
  static func wholeImage() -> (image: Data, member: Data) {
    let stored = Data(repeating: 0x72, count: 4096)
    let tail = Data(repeating: 0x69, count: 512) + Data("koly".utf8) + Data(count: 508)
    let image = xzInput + stored + tail
    return (
      image,
      member(
        image: image,
        chunks: [
          Chunk(output: 4096, stored: xzChunk), Chunk(output: 4096, stored: stored),
          Chunk(output: tail.count, stored: tail),
        ])
    )
  }

  func decode(_ member: Data, header: Data? = nil, split: Int? = nil) throws -> Data {
    let parsed = try UpdateArchiveFullImage.Header(
      (header ?? member).prefix(UpdateArchiveFullImage.headerBytes), memberBytes: member.count)
    let decoder = UpdateArchiveFullImage.Decoder(header: parsed)
    var output = Data()
    var offset = 0
    while offset < member.count {
      let end = min(member.count, offset + (split ?? member.count))
      try decoder.consume(member.subdata(in: offset..<end)) { output += $0 }
      offset = end
    }
    try decoder.finish()
    return output
  }

  func testAWholeImageDecodesFromXZAndStoredChunksHoweverItsBytesArrive() throws {
    let (image, member) = Self.wholeImage()
    for split in [nil, 1, 7, 60, 72, 4097] {
      XCTAssertEqual(try decode(member, split: split), image, "split \(String(describing: split))")
    }
  }

  func testAPatchOfAnEarlierImageIsRefused() {
    let (image, _) = Self.wholeImage()
    let member = Self.member(
      image: image, chunks: [Chunk(output: image.count, stored: image)], chunkBytes: 1 << 20,
      control: 1)
    XCTAssertThrowsError(try decode(member)) {
      XCTAssertTrue($0 is UpdateArchiveImagePatchUnsupported, "\($0)")
    }
  }

  func testTheHeaderMustDescribeItsMember() throws {
    let (_, member) = Self.wholeImage()
    let header = member.prefix(UpdateArchiveFullImage.headerBytes)
    XCTAssertNoThrow(try UpdateArchiveFullImage.Header(header, memberBytes: member.count))
    for size in [member.count - 1, member.count + 1] {
      XCTAssertThrowsError(try UpdateArchiveFullImage.Header(header, memberBytes: size))
    }
    var magic = Data(header)
    magic[0] = 0x41
    XCTAssertThrowsError(try UpdateArchiveFullImage.Header(magic, memberBytes: member.count))
    XCTAssertThrowsError(
      try UpdateArchiveFullImage.Header(header.prefix(59), memberBytes: member.count))
    let empty = Self.member(image: Data(), chunks: [])
    XCTAssertThrowsError(
      try UpdateArchiveFullImage.Header(
        empty.prefix(UpdateArchiveFullImage.headerBytes), memberBytes: empty.count))
  }

  func testAnOversizedStreamLengthIsRefusedWithoutOverflow() {
    let (_, member) = Self.wholeImage()
    for stream in [Int.max, Int.max - UpdateArchiveFullImage.headerBytes + 1] {
      var header = Data(member.prefix(UpdateArchiveFullImage.headerBytes))
      header.replaceSubrange(32..<40, with: Self.little(stream).prefix(8))
      XCTAssertThrowsError(try UpdateArchiveFullImage.Header(header, memberBytes: member.count))
      XCTAssertThrowsError(try UpdateArchiveFullImage.Header(header, memberBytes: 8 << 30))
    }
    XCTAssertThrowsError(
      try UpdateArchiveFullImage.Header(
        member.prefix(UpdateArchiveFullImage.headerBytes),
        memberBytes: UpdateArchiveFullImage.headerBytes - 1))
  }

  func testTheOutputMustMatchApplesSHA1() {
    let (image, _) = Self.wholeImage()
    var changed = image
    changed[5000] ^= 1
    let member = Self.member(
      image: changed, chunks: [Chunk(output: changed.count, stored: changed)],
      chunkBytes: 1 << 20, sha1: Data(Insecure.SHA1.hash(data: image)))
    XCTAssertThrowsError(try decode(member))
  }

  func testTheStreamedHeaderMustBeTheOneThePlanRead() {
    let (image, member) = Self.wholeImage()
    var other = image
    other[0] ^= 1
    let planned = Self.member(
      image: other, chunks: [Chunk(output: other.count, stored: other)], chunkBytes: 1 << 20)
    // Same lengths, another SHA-1: the plan's header can't vouch for this member.
    var header = Data(member.prefix(UpdateArchiveFullImage.headerBytes))
    header.replaceSubrange(40..<60, with: planned.subdata(in: 40..<60))
    XCTAssertThrowsError(try decode(member, header: header))
  }

  func testATruncatedOrOverlongStreamIsRefused() throws {
    let (_, member) = Self.wholeImage()
    let header = try UpdateArchiveFullImage.Header(
      member.prefix(UpdateArchiveFullImage.headerBytes), memberBytes: member.count)
    let short = UpdateArchiveFullImage.Decoder(header: header)
    try short.consume(member.dropLast()) { _ in }
    XCTAssertThrowsError(try short.finish())
    let long = UpdateArchiveFullImage.Decoder(header: header)
    XCTAssertThrowsError(try long.consume(member + Data([0])) { _ in })
    let done = UpdateArchiveFullImage.Decoder(header: header)
    try done.consume(member) { _ in }
    try done.finish()
    XCTAssertThrowsError(try done.finish())
    XCTAssertThrowsError(try done.consume(Data()) { _ in })
  }

  func testChunkLengthsAreBounded() {
    let (image, _) = Self.wholeImage()
    let cases: [(String, [Chunk], Int)] = [
      ("stored longer than its output", [Chunk(output: 10, stored: image.prefix(11))], 4096),
      ("output beyond the chunk size", [Chunk(output: 5000, stored: image.prefix(5000))], 4096),
      ("empty chunk", [Chunk(output: 0, stored: Data())], 4096),
      ("oversized chunk size", [Chunk(output: 10, stored: image.prefix(10))], 32 << 20),
      ("zero chunk size", [Chunk(output: 10, stored: image.prefix(10))], 0),
      (
        "output beyond the image",
        [
          Chunk(output: 4096, stored: image.prefix(4096)),
          Chunk(output: 4096, stored: image.prefix(4096)),
        ], 4096
      ),
    ]
    for (name, chunks, size) in cases {
      let output = chunks.reduce(Data()) { $0 + $1.stored }
      let member = Self.member(
        image: output, chunks: chunks, chunkBytes: size,
        outputBytes: name == "output beyond the image" ? 4096 : nil)
      XCTAssertThrowsError(try decode(member), name)
    }
  }

  func testAnXZChunkMustDecodeToExactlyItsDeclaredLength() {
    for declared in [4095, 4097] {
      let member = Self.member(
        image: Self.xzInput, chunks: [Chunk(output: declared, stored: Self.xzChunk)],
        chunkBytes: 8192, outputBytes: declared)
      XCTAssertThrowsError(try decode(member), "\(declared)")
    }
    var damaged = Self.xzChunk
    damaged[40] ^= 0xff
    let member = Self.member(
      image: Self.xzInput, chunks: [Chunk(output: 4096, stored: damaged)])
    XCTAssertThrowsError(try decode(member))
  }

  func testTheStreamMustBePBZX() {
    let (_, member) = Self.wholeImage()
    var changed = member
    changed[UpdateArchiveFullImage.headerBytes] = 0x41
    XCTAssertThrowsError(try decode(changed, header: member))
  }
}

extension Data {
  fileprivate init(hex: String) {
    let digits = Array(hex.utf8)
    self.init(
      stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
      })
  }
}
