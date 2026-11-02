import Foundation

/// A PTY read can end inside a CRLF or a multi-byte character; the next
/// cumulative snapshot must still continue it, never repeat it.
@main struct Check {
  static func spin(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.02))) }
  }

  static func output(_ snapshots: [String]) -> [String] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aurora-command-log-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = InstallerLog(directory: root)
    let command = CommandLog("/usr/bin/kmutil", ["configure-boot"], log: log)
    for snapshot in snapshots { command.output(snapshot) }
    command.finish(status: 0)
    spin(0.3)
    return log.entries.dropFirst().dropLast().map(\.message)
  }

  static func main() {
    let crlf = output([
      "Preparing\r\nStep 1\r\nStep 2\r", "Preparing\r\nStep 1\r\nStep 2\r\nStep 3\r\n",
    ])
    precondition(crlf == ["Preparing", "Step 1", "Step 2", "Step 3"], "split CRLF: \(crlf)")

    // String(cString:) turns a read that ends inside "é" into U+FFFD.
    let accent = output(["caf\u{FFFD}", "café\n"])
    precondition(accent == ["café"], "split é: \(accent)")

    let held = output(["done\r"])
    precondition(held == ["done"], "a held carriage return still ends the line: \(held)")

    let invisible = InstallerLogRedactor.lines("ab\u{202E}cd\u{200B}ef\u{2066}g")
    precondition(invisible == ["abcdefg"], "format characters: \(invisible)")
    print(
      "PASS split CRLF and multi-byte reads continue without repeats; format characters removed")
  }
}
