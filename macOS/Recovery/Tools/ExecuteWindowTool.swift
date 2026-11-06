import Foundation

/// Pads an aura Mach-O boot object for a larger code-execute window and writes
/// the result to a file, sparse, for inspection or a manual enrollment. Recovery
/// does the same through `MachOBootObject.expandExecuteWindow` when it enrolls.
@main struct ExecuteWindowTool {
  static let usage = """
    usage: aura-execute-window [--window-mib N] [--slot-mib N] [--stage2 PATH] [-o OUTPUT] OBJECT

    Writes OBJECT with its __TEXT_EXEC padded so that it holds aura and an aligned
    window of N MiB (default \(ExecuteWindow.size >> 20), with \(ExecuteWindow.auraSlot >> 20) MiB kept for aura). --stage2 changes
    the ESP path its filled Stage 1 chainloads. An object filled for \(AuraStage1Format.standardStage2Path) needs
    --stage2 \(AuraStage1Format.confinedStage2Path) to load the Stage 2 updates keep current. Without -o the
    output goes to a new temporary file, whose path is the last line printed.

    """

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }

  static func main() {
    var window = ExecuteWindow.size
    var slot = ExecuteWindow.auraSlot
    var stage2: String?
    var output: URL?
    var input: URL?
    var arguments = Array(CommandLine.arguments.dropFirst())[...]
    func mebibytes(_ flag: String) -> UInt64 {
      guard let value = arguments.popFirst().flatMap({ UInt64($0) }), value <= 1 << 20 else {
        fail("\(flag) needs a number of MiB\n\n" + usage)
      }
      return value << 20
    }
    while let argument = arguments.popFirst() {
      switch argument {
      case "--window-mib": window = mebibytes(argument)
      case "--slot-mib": slot = mebibytes(argument)
      case "--stage2":
        guard let path = arguments.popFirst() else { fail(usage) }
        stage2 = path
      case "-o":
        guard let path = arguments.popFirst() else { fail(usage) }
        output = URL(fileURLWithPath: path)
      case "-h", "--help":
        print(usage)
        return
      default:
        guard input == nil, !argument.hasPrefix("-") else { fail(usage) }
        input = URL(fileURLWithPath: argument)
      }
    }
    guard let input else { fail(usage) }
    do {
      var object = try Data(contentsOf: input)
      if let stage2 { object = try Stage1Configuration.retargeted(object, stage2Path: stage2) }
      let expanded = try MachOBootObject.expandExecuteWindow(object, window: window, slot: slot)
      let path =
        output
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "aura-boot-expanded-" + UUID().uuidString + ".macho")
      try expanded.write(to: path)
      var info = stat()
      guard stat(path.path, &info) == 0 else { fail("cannot inspect \(path.path)") }
      print("input:      \(object.count) bytes")
      print("size:       \(expanded.size) bytes")
      print("on disk:    \(UInt64(info.st_blocks) * 512) bytes")
      print("kcrz:       \(expanded.readOnlySize) bytes (expected from kmutil)")
      print("enroll in paired Recovery:")
      print("  kmutil configure-boot -c \(path.path) -v <volume> --compress")
      print(path.path)
    } catch {
      fail(error.localizedDescription)
    }
  }
}
