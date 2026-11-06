#if os(macOS)
  import AuroraFirmware
  import Foundation
  import RecoveryAccountCore
  import zlib

  enum NativeBootChainError: Error, Equatable {
    case invalidQualification
    case unsupportedBoard
    case missingStage1
    case missingStage2
    case invalidStage1
    /// A Mach-O chip has no raw or unpadded Stage 1 to fall back to.
    case missingMachOStage1
    /// The payload has no Stage 2 for a padded Stage 1 to load.
    case missingConfinedStage2
    /// That Stage 2 is larger than the slot aura keeps, so it could not load.
    case confinedStage2TooLarge
  }

  struct NativeBootChainAdmission: Equatable, Sendable {
    let stage1Member: String?
    /// The Mach-O boot object wrapping the common Stage 1, for chips that use it.
    var stage1MachOMember: String? = nil
    /// The padded object's whole size, which enrollment needs room for.
    var expandedStage1Bytes: UInt64? = nil
    let windowMilliseconds: UInt32
    let espLayout: [String: String]

    /// The ESP file the enrolled Stage 1 chainloads.
    var stage2Path: String { AuraStage1Format.stage2Path(machO: stage1MachOMember != nil) }
  }

  enum NativeBootChain {
    static let commonStage1 = "esp/aurora/stage1.bin"
    static let commonStage1MachO = "esp/aurora/stage1.macho"

    /// `machOStage1` asks for the padded Mach-O Stage 1 (AuraStage1Format.usesMachO).
    /// Such a Mac needs the object and its Stage 2, or nothing it can start from is
    /// installed. Only the dry run lifts `requireConfinedStage2`, to report the rest
    /// of the chain for a payload published before that file existed.
    static func admit(
      metadata: Data, archive: IPSWArchive, deviceIdentifier: String, firmware: String,
      machOStage1: Bool = false, requireConfinedStage2: Bool = true
    ) async throws -> NativeBootChainAdmission {
      let template = try NativePayloadPreflight.target(metadata)
      let board = String(deviceIdentifier.dropFirst(6)) + "ap"
      guard deviceIdentifier.hasPrefix("apple,"),
        NativeHandoffEvidence.safeRelative(board)
      else { throw NativeBootChainError.unsupportedBoard }
      for (key, allowed) in [("allowed_device_classes", true), ("excluded_device_classes", false)] {
        if let value = template[key] {
          if value is NSNull {
            guard allowed else { throw NativeBootChainError.unsupportedBoard }
            continue
          }
          guard let values = value as? [String], values.contains(board) == allowed else {
            throw NativeBootChainError.unsupportedBoard
          }
        }
      }
      let members = Dictionary(
        uniqueKeysWithValues: archive.members.filter { !$0.isDirectory }.map {
          ($0.name, $0)
        })
      let qualified = try qualifiedFirmware(template: template, board: board)
      let common = members[commonStage1] != nil && qualified.contains(firmware)
      var stage1: String?
      var stage1MachO: String?
      var expandedStage1: UInt64?
      var window: UInt32 = 0
      if machOStage1, !common || members[commonStage1MachO] == nil {
        throw NativeBootChainError.missingMachOStage1
      }
      if common {
        stage1 = commonStage1
      } else if board == "j700ap" {
        stage1 = "esp/aurora/stage1-j700.bin"
        window = 5000
      } else if board == "j613ap", firmware == "26.6.2" {
        stage1 = "esp/aurora/stage1-j613.bin"
      }
      if let stage1 {
        guard let member = members[stage1] else { throw NativeBootChainError.missingStage1 }
        let bytes = try await archive.read(member, maximumBytes: 64 << 20)
        let filled = try fillStage1(
          bytes, uuid: "00000000-0000-0000-0000-000000000000",
          path: machOStage1
            ? AuraStage1Format.confinedStage2Path
            : template["next_object"] as? String ?? AuraStage1Format.standardStage2Path,
          windowMilliseconds: window)
        if machOStage1, let object = members[commonStage1MachO] {
          do {
            // Recovery pads the object after partitioning, so refuse here what it would refuse.
            let carried = try MachOBootObject.fill(
              try await archive.read(object, maximumBytes: 64 << 20), raw: bytes, filled: filled)
            expandedStage1 = try MachOBootObject.expandExecuteWindow(carried).size
          } catch is MachOBootObject.Invalid {
            throw NativeBootChainError.invalidStage1
          }
          stage1MachO = commonStage1MachO
        }
      }
      let stage2 = try stage2Selection(template: template, board: board)
      let esp = Set(members.keys.filter { $0.hasPrefix("esp/") })
      let layout = try NativeESPLayout.map(
        deviceIdentifier: deviceIdentifier, members: esp, commonAllowed: common,
        stage2: stage2.member,
        stage2Variants: stage2.variants, machOStage1: machOStage1)
      guard let selected = layout.first(where: { $0.value == "m1n1/boot.bin" })?.key,
        let member = members[selected], member.sizeBytes > 0
      else { throw NativeBootChainError.missingStage2 }
      if machOStage1, requireConfinedStage2 {
        guard
          let confined = layout.first(where: {
            $0.value == AuraStage1Format.confinedStage2Path
          })?.key,
          let file = members[confined], file.sizeBytes > 0
        else { throw NativeBootChainError.missingConfinedStage2 }
        guard UInt64(file.sizeBytes) <= ExecuteWindow.auraSlot else {
          throw NativeBootChainError.confinedStage2TooLarge
        }
      }
      return NativeBootChainAdmission(
        stage1Member: stage1, stage1MachOMember: stage1MachO, expandedStage1Bytes: expandedStage1,
        windowMilliseconds: window, espLayout: layout)
    }

    static func qualifiedFirmware(template: [String: Any], board: String) throws -> [String] {
      guard let policy = template["aurora_stage1"], !(policy is NSNull) else { return [] }
      guard let values = policy as? [String: Any],
        Set(values.keys) == ["kind", "qualified_machines"],
        values["kind"] as? String == "common-raw-v1",
        let machines = values["qualified_machines"] as? [String: [String]]
      else { throw NativeBootChainError.invalidQualification }
      return machines[board] ?? []
    }

    static func stage2Selection(template: [String: Any], board: String) throws -> (
      member: String?, variants: Set<String>
    ) {
      let standard = "esp/m1n1/boot.bin"
      guard let policy = template["aurora_stage2"] else { return (nil, []) }
      guard let values = policy as? [String: Any],
        Set(values.keys) == ["kind", "board_members"],
        values["kind"] as? String == "board-file-v1",
        let boardMembers = values["board_members"] as? [String: String],
        !boardMembers.isEmpty,
        boardMembers.keys.allSatisfy({
          $0.range(of: #"\Aj[0-9]+[a-z]*ap\z"#, options: .regularExpression) != nil
        }),
        boardMembers.values.allSatisfy({
          $0.hasPrefix("esp/m1n1/") && $0.hasSuffix(".bin")
            && NativeHandoffEvidence.safeRelative($0)
        }),
        Set(boardMembers.values).count == boardMembers.count
      else { throw NativeBootChainError.invalidQualification }
      return (boardMembers[board] ?? standard, Set(boardMembers.values).union([standard]))
    }

    static func fillStage1(
      _ image: Data, uuid: String, path: String, windowMilliseconds: UInt32
    ) throws -> Data {
      let magic = Data("AURORA-S1-CFG01\0".utf8)
      let blockBytes = magic.count + 240 + 4
      guard
        uuid.range(
          of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#,
          options: .regularExpression) != nil,
        NativeHandoffEvidence.safeRelative(path),
        path.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7f && $0 != 0x3b }),
        path.utf8.count + 1 < 192, windowMilliseconds <= 99999,
        image.suffix(8) == Data("STACKBOT".utf8),
        let range = image.range(of: magic),
        image.range(of: magic, in: (range.lowerBound + 1)..<image.count) == nil,
        range.lowerBound <= image.count - 8 - blockBytes
      else { throw NativeBootChainError.invalidStage1 }
      let offset = range.upperBound
      guard image[offset..<(offset + 4)].elementsEqual([1, 0, 0, 0]) else {
        throw NativeBootChainError.invalidStage1
      }
      var body = Data([1, 0, 0, 0])
      body.append(
        contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: windowMilliseconds >> ($0 * 8)) })
      body.append(Data(uuid.utf8))
      body.append(Data(repeating: 0, count: 4))
      let encoded = Data((";" + path).utf8)
      body.append(encoded)
      body.append(Data(repeating: 0, count: 192 - encoded.count))
      let crc = body.withUnsafeBytes {
        UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(body.count)))
      }
      body.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) })
      var result = Data(image.prefix(range.lowerBound))
      result.append(magic)
      result.append(body)
      result.append(image.suffix(from: range.lowerBound + blockBytes))
      return result
    }

    /// A cross-distro Reset keeps the already enrolled executable bytes. Check
    /// the existing trampoline's bounded configuration against this exact ESP
    /// instead of requiring another distro's build to reproduce its code bytes.
    static func validateInstalledStage1(_ image: Data, uuid: String, path: String) throws {
      let magic = Data("AURORA-S1-CFG01\0".utf8)
      let blockBytes = magic.count + 244
      guard
        uuid.range(
          of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#,
          options: .regularExpression) != nil,
        NativeHandoffEvidence.safeRelative(path),
        image.count >= blockBytes + 8,
        image.suffix(8) == Data("STACKBOT".utf8),
        let range = image.range(of: magic),
        image.range(of: magic, in: (range.lowerBound + 1)..<image.count) == nil,
        range.lowerBound <= image.count - 8 - blockBytes
      else { throw NativeBootChainError.invalidStage1 }
      let body = Data(image[range.upperBound..<(range.lowerBound + blockBytes)])
      let encoded = Data((";" + path).utf8)
      guard body.count == 244,
        body[0..<4].elementsEqual([1, 0, 0, 0]),
        body[8..<44] == Data(uuid.utf8),
        body[44..<48] == Data(repeating: 0, count: 4),
        encoded.count < 192,
        body[48..<(48 + encoded.count)] == encoded,
        body[(48 + encoded.count)..<240].allSatisfy({ $0 == 0 })
      else { throw NativeBootChainError.invalidStage1 }
      let window = body[4..<8].enumerated().reduce(UInt32(0)) { result, pair in
        result | (UInt32(pair.element) << (pair.offset * 8))
      }
      guard window <= 99_999 else { throw NativeBootChainError.invalidStage1 }
      let framed = Data(body.prefix(240))
      let checksum = framed.withUnsafeBytes {
        UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(framed.count)))
      }
      guard
        body.suffix(4).elementsEqual(
          (0..<4).map { UInt8(truncatingIfNeeded: checksum >> ($0 * 8)) })
      else { throw NativeBootChainError.invalidStage1 }
    }
  }

  enum NativeESPLayout {
    /// On a Mach-O chip a board's own confined Stage 2 wins over the shared one,
    /// and either goes beside `m1n1/boot.bin`. Other chips never receive one.
    static func map(
      deviceIdentifier: String, members: Set<String>, commonAllowed: Bool, stage2: String?,
      stage2Variants: Set<String>, machOStage1: Bool = false
    ) throws -> [String: String] {
      let standard = "esp/m1n1/boot.bin"
      let board = String(deviceIdentifier.dropFirst(6))
      let conventional = "esp/m1n1/boot-\(board).bin"
      let selected = stage2 ?? (members.contains(conventional) ? conventional : standard)
      let common = members.contains("esp/aurora/stage1.bin") && commonAllowed
      let confined =
        machOStage1
        ? ["esp/m1n1/boot-ctxr-\(board).bin", "esp/m1n1/boot-ctxr.bin"].first(
          where: members.contains) : nil
      guard members.contains(selected)
      else { throw NativeHandoffValidationError.changedContent }
      var layout = [String: String]()
      for member in members.sorted() {
        guard member.hasPrefix("esp/"), NativeHandoffEvidence.safeRelative(member) else {
          throw NativeHandoffValidationError.unsafePath
        }
        if member == selected {
          layout[member] = "m1n1/boot.bin"
        } else if member == confined {
          layout[member] = AuraStage1Format.confinedStage2Path
        } else if (!common
          && [NativeBootChain.commonStage1, NativeBootChain.commonStage1MachO].contains(member))
          || stage2Variants.contains(member)
          || (selected != standard && member == standard)
          || (member.hasPrefix("esp/m1n1/boot-") && member.hasSuffix(".bin"))
          || (common
            && ["esp/aurora/stage1-j700.bin", "esp/aurora/stage1-j613.bin"].contains(member))
        {
          continue
        } else {
          layout[member] = String(member.dropFirst(4))
        }
      }
      guard !layout.isEmpty, Set(layout.values).count == layout.count else {
        throw NativeHandoffValidationError.changedContent
      }
      return layout
    }
  }
#endif
