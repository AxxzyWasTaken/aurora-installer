// Based on aurora-audio-dsp by saku (MIT): the collection of the machine's
// own AID<n> tuning folder through the device tree's `acoustic-id`, and of
// the per-unit `speaker-thiele-small` calibration, follows saku's
// tools/macos-collector/collect-audio-tuning.sh.
//
// Copyright (c) 2026 saku
// Copyright (c) 2026 The Aurora Silicon Contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

#if os(macOS)
  import Darwin
  import Foundation
  import IOKit

  /// This Mac's own speaker tuning, read only from the running macOS.
  ///
  /// The device tree's audio node names the tuning folder (`acoustic-id`
  /// 35 selects `AID35`) and, on Macs with speaker calibration, carries the
  /// per-unit `speaker-thiele-small` record. Both are copied unchanged into
  /// the per-machine vendor firmware, beside Wi-Fi, Bluetooth and camera
  /// firmware, for the Linux speaker protection to read. Nothing here is
  /// shipped by the installer: the data comes from the user's own system
  /// volume and stays on the user's own ESP.
  enum NativeAudioTuningInputs {
    /// Where the tuning folders live on the sealed system volume.
    static let tuningsPrefix = "System/Library/Audio/Tunings"
    /// Names in the firmware package (`/lib/firmware/vendor/` on Linux).
    static let packagePrefix = "apple/audio-tuning/"
    /// Names in the raw fallback archive (`asahi/all_firmware.tar.gz`).
    static let fallbackPrefix = "audio-tuning/"
    static let manifestName = "manifest.json"
    static let thieleSmallName = "speaker-thiele-small.bin"
    /// AID35 is 34 files and 2.4 MB; these bounds leave ample room.
    static let maximumFiles = 1024
    static let maximumBytes = 64 << 20
    /// The manifest schema. 2 adds `source_file_count` and `complete`.
    static let schema = 2

    struct Snapshot: Sendable, Equatable {
      /// The `acoustic-id` value, e.g. 35.
      var acousticID: UInt32
      /// Raw `speaker-thiele-small`. Absent on Macs without speaker
      /// calibration (Mac mini, iMac, Mac Studio), which still get tuning.
      var thieleSmall: Data?
      /// Files of the `AID<n>` folder, by path relative to it.
      var files: [String: Data]
      /// The macOS build the files came from, e.g. 25G83.
      var build: String
      /// The machine's selection data from the Tunings root, by bundle path:
      /// `DeviceDSPDatabase.plist` holding only this Mac's `AID<n>` entry
      /// (the speaker configurations and the graph, strip and property
      /// strip each uses), and `Config/AID<n>.plist` unchanged (output
      /// volume ranges and scalars).
      var selection: [String: Data] = [:]
      /// Admitted entries of the source folder (regular files and links to
      /// them). Nil means `files.count`; anything else must equal it.
      var sourceFileCount: Int? = nil
    }

    struct Manifest: Codable, Equatable {
      struct File: Codable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
      }
      let schema: Int
      let kind: String
      /// Entries of the source `AID<n>` folder; equals the `AID<n>/`
      /// records in `files`.
      let sourceFileCount: Int
      /// True only for a full set: every folder entry and both selection
      /// files. Readers refuse anything else.
      let complete: Bool
      let acousticID: UInt32
      let aid: String
      let macOSBuild: String
      let speakerThieleSmall: File?
      /// Bundle path of the filtered DSP database, when the Mac has an entry.
      let deviceDSPDatabase: String?
      /// Bundle path of `Config/AID<n>.plist`, when present.
      let config: String?
      let files: [File]
      let basedOn: String

      enum CodingKeys: String, CodingKey {
        case schema, kind, aid, files, config, complete
        case sourceFileCount = "source_file_count"
        case acousticID = "acoustic_id"
        case macOSBuild = "macos_build"
        case speakerThieleSmall = "speaker_thiele_small"
        case deviceDSPDatabase = "device_dsp_database"
        case basedOn = "based_on"
      }
    }

    static let databaseName = "DeviceDSPDatabase.plist"
    static func configName(_ acousticID: UInt32) -> String {
      "Config/" + folder(acousticID) + ".plist"
    }

    /// This Mac's entry of the DSP database, as a property list with that
    /// one key. Nil when the database has no entry for it.
    static func databaseEntry(_ database: Data, acousticID: UInt32) throws -> Data? {
      guard
        let root = try PropertyListSerialization.propertyList(from: database, format: nil)
          as? [String: Any]
      else { throw NativePeripheralInputError.localInput }
      let key = folder(acousticID)
      guard let entry = root[key] else { return nil }
      return try PropertyListSerialization.data(
        fromPropertyList: [key: entry], format: .xml, options: 0)
    }

    /// `AID<n>`, the folder name for an acoustic ID.
    static func folder(_ acousticID: UInt32) -> String { "AID\(acousticID)" }

    /// The device tree stores `acoustic-id` as one little-endian 32-bit word.
    static func acousticID(_ bytes: Data) -> UInt32? {
      guard bytes.count == 4 else { return nil }
      let value = bytes.enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << (8 * $1.offset)
      }
      guard value > 0, value < 100_000 else { return nil }
      return value
    }

    /// A tuning file name is a plain relative path; macOS AppleDouble and
    /// Finder sidecars are not tuning data.
    static func admitted(_ relative: String) -> Bool {
      guard NativeHandoffEvidence.safeRelative(relative), !relative.hasPrefix("/") else {
        return false
      }
      return !relative.split(separator: "/").contains {
        $0.hasPrefix("._") || $0 == ".DS_Store"
      }
    }

    /// The live snapshot, or nil on a Mac without an audio node or without a
    /// tuning folder for it.
    static func live(owner: uid_t) throws -> Snapshot? {
      guard let (acoustic, thieleSmall) = try properties(),
        let acousticID = acousticID(acoustic)
      else { return nil }
      let root = URL(fileURLWithPath: "/", isDirectory: true)
      let prefix = tuningsPrefix + "/" + folder(acousticID)
      var info = stat()
      guard lstat(root.appendingPathComponent(prefix).path, &info) == 0,
        info.st_mode & S_IFMT == S_IFDIR
      else { return nil }
      let tree = try NativeHandoffFileTree(
        root, protected: true, owner: owner, readOnlyVolume: true)
      let descriptor = try tree.fileDescriptor(prefix)
      defer { close(descriptor) }
      guard NativeHandoffFileTree.isReadOnly(descriptor) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      let snapshot = try NativeFirmwareInputFiles.snapshot(
        root: root, prefix: prefix, tree: tree, owner: owner)
      let (files, count) = try admittedFiles(snapshot)
      var selection = [String: Data]()
      let database = tuningsPrefix + "/" + databaseName
      if try !tree.isAbsent(database),
        let entry = try databaseEntry(
          NativeFirmwareInputFiles.read(tree, path: database, maximum: 64 << 20, owner: owner),
          acousticID: acousticID)
      {
        selection[databaseName] = entry
      }
      let config = tuningsPrefix + "/" + configName(acousticID)
      if try !tree.isAbsent(config) {
        selection[configName(acousticID)] = try NativeFirmwareInputFiles.read(
          tree, path: config, maximum: 1 << 20, owner: owner)
      }
      return Snapshot(
        acousticID: acousticID, thieleSmall: thieleSmall, files: files, build: build(),
        selection: selection, sourceFileCount: count)
    }

    /// The folder's admitted files, with each admitted link kept as a copy
    /// of its target, and the number of admitted entries. A link that does
    /// not end at a regular file of the folder fails the whole set, so a
    /// short read never becomes a bundle.
    static func admittedFiles(
      _ snapshot: NativeFirmwareInputFiles.Snapshot
    ) throws -> (files: [String: Data], count: Int) {
      var files = [String: Data]()
      var count = 0
      for (name, data) in snapshot.files where admitted(name) {
        files[name] = data
        count += 1
      }
      guard !snapshot.unresolved.contains(where: admitted) else {
        throw NativeFirmwareInputFailure.invalidSource
      }
      for (alias, target) in snapshot.links where admitted(alias) {
        guard let data = snapshot.files[target] else {
          throw NativeFirmwareInputFailure.invalidSource
        }
        files[alias] = data
        count += 1
      }
      return (files, count)
    }

    /// `acoustic-id` and `speaker-thiele-small` of the one device-tree audio
    /// node that carries an acoustic ID. Nil when there is none.
    static func properties() throws -> (Data, Data?)? {
      func read(_ entry: io_registry_entry_t) -> (Data, Data?)? {
        guard
          let acoustic = IORegistryEntryCreateCFProperty(
            entry, "acoustic-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? Data
        else { return nil }
        let spts =
          IORegistryEntryCreateCFProperty(
            entry, "speaker-thiele-small" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? Data
        return (acoustic, spts)
      }
      let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product/audio")
      if product != 0 {
        defer { IOObjectRelease(product) }
        if let found = read(product) { return found }
      }
      var iterator: io_iterator_t = 0
      guard
        IORegistryCreateIterator(
          kIOMainPortDefault, kIODeviceTreePlane, IOOptionBits(kIORegistryIterateRecursively),
          &iterator) == KERN_SUCCESS
      else { return nil }
      defer { IOObjectRelease(iterator) }
      var found: (Data, Data?)?
      var count = 0
      while true {
        try Task.checkCancellation()
        let entry = IOIteratorNext(iterator)
        if entry == 0 { break }
        defer { IOObjectRelease(entry) }
        count += 1
        guard count <= 65_536 else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetNameInPlane(entry, kIODeviceTreePlane, &name) == KERN_SUCCESS,
          String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            == "audio",
          let properties = read(entry)
        else { continue }
        // Two audio nodes with acoustic IDs leave the folder ambiguous.
        guard found == nil else { throw NativePeripheralInputError.localInput }
        found = properties
      }
      return found
    }

    static func build() -> String {
      var size = 0
      guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0, size < 64 else {
        return "unknown"
      }
      var bytes = [CChar](repeating: 0, count: size)
      guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
      let value = String(
        decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      return value.range(of: #"\A[0-9A-Za-z]{1,16}\z"#, options: .regularExpression) == nil
        ? "unknown" : value
    }

    /// The package files for a snapshot, under `prefix`: the folder's files
    /// below `AID<n>/`, the calibration record and a manifest with every
    /// file's size and SHA-256. Empty for no snapshot.
    static func files(_ snapshot: Snapshot?, prefix: String) throws -> [String: Data] {
      guard let snapshot else { return [:] }
      guard !snapshot.files.isEmpty, snapshot.files.count <= maximumFiles,
        (snapshot.sourceFileCount ?? snapshot.files.count) == snapshot.files.count
      else {
        throw NativePeripheralInputError.localInput
      }
      // Only a complete set is a bundle: both selection files are required.
      guard snapshot.selection[databaseName] != nil,
        snapshot.selection[configName(snapshot.acousticID)] != nil
      else { throw NativePeripheralInputError.localInput }
      let aid = folder(snapshot.acousticID)
      var result = [String: Data]()
      var records = [Manifest.File]()
      var total = 0
      for name in snapshot.files.keys.sorted() {
        let data = snapshot.files[name]!
        guard admitted(name), data.count <= maximumBytes - total else {
          throw NativePeripheralInputError.localInput
        }
        total += data.count
        result[prefix + aid + "/" + name] = data
        records.append(
          Manifest.File(
            path: aid + "/" + name, bytes: data.count, sha256: NativeStubFileStore.hash(data)))
      }
      for name in snapshot.selection.keys.sorted() {
        let data = snapshot.selection[name]!
        guard name == databaseName || name == configName(snapshot.acousticID),
          !data.isEmpty, data.count <= maximumBytes - total
        else { throw NativePeripheralInputError.localInput }
        total += data.count
        result[prefix + name] = data
        records.append(
          Manifest.File(path: name, bytes: data.count, sha256: NativeStubFileStore.hash(data)))
      }
      var thieleSmall: Manifest.File?
      if let spts = snapshot.thieleSmall {
        guard !spts.isEmpty, spts.count <= 4096 else {
          throw NativePeripheralInputError.localInput
        }
        result[prefix + thieleSmallName] = spts
        thieleSmall = Manifest.File(
          path: thieleSmallName, bytes: spts.count, sha256: NativeStubFileStore.hash(spts))
      }
      let manifest = Manifest(
        schema: schema, kind: "aurora-audio-tuning", sourceFileCount: snapshot.files.count,
        complete: true, acousticID: snapshot.acousticID, aid: aid,
        macOSBuild: snapshot.build, speakerThieleSmall: thieleSmall,
        deviceDSPDatabase: databaseName, config: configName(snapshot.acousticID),
        files: records,
        basedOn: "aurora-audio-dsp by saku (MIT)")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
      result[prefix + manifestName] = try encoder.encode(manifest)
      return result
    }

    /// Collection never stops an installation: Linux falls back to its
    /// family profiles without it. A cancellation still ends the step.
    static func collect(
      _ source: @Sendable (uid_t) throws -> Snapshot?, owner: uid_t
    ) throws -> (package: [String: Data], fallback: [String: Data]) {
      do {
        let snapshot = try source(owner)
        return (
          try files(snapshot, prefix: packagePrefix), try files(snapshot, prefix: fallbackPrefix)
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return ([:], [:])
      }
    }
  }
#endif
