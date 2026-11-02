import Foundation

@main struct Check {
  static func spin(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(until: min(end, Date().addingTimeInterval(0.02))) }
  }
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aurora-log-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = InstallerLog(directory: root, displayLimit: 1_000)
    var publications = 0
    log.onChange = { publications += 1 }
    defer { log.onChange = nil }

    // A command: redacted heading, output as detail lines (PTY snapshots
    // are cumulative and may end mid-line), and a failure with its tail.
    let command = CommandLog(
      "/usr/bin/bputil", ["-nc", "-v", "GROUP", "--user", "owner"], secrets: ["hunter2"], log: log)
    command.output("first")
    command.output("first output\r\n\u{1B}[31mpassword: hunter2\u{1B}[0m\nsecond ")
    command.output("first output\r\n\u{1B}[31mpassword: hunter2\u{1B}[0m\nsecond ")
    command.output("first output\r\n\u{1B}[31mpassword: hunter2\u{1B}[0m\nsecond half\nthird\n")
    command.finish(status: 2, reason: "Authorization failed: refused")
    log.append("Setup failed: bputil failed.", level: .error)
    spin(0.3)
    let entries = log.entries
    try require(
      entries.map(\.message) == [
        "Started #1: /usr/bin/bputil -nc -v GROUP --user [redacted]", "first output",
        "password: [redacted]", "second half", "third",
        "Authorization failed: refused after "
          + entries[5].message.split(separator: " ")
          .suffix(3).joined(separator: " "),
        "output: password: [redacted]", "output: second half", "output: third",
        "Setup failed: bputil failed.",
      ], "command lines: \(entries.map(\.message))")
    try require(
      entries.map(\.level) == [
        .debug, .debug, .debug, .debug, .debug, .error, .error, .error, .error, .error,
      ], "levels")
    try require(entries.allSatisfy { !$0.message.contains("hunter2") }, "secret redacted")
    try require(Set(entries.prefix(9).map(\.source)) == ["bputil"], "sources")
    try require(entries[0].activity == "bputil#1" && entries[5].closesActivity, "activity")
    try require(log.running.isEmpty, "a finished command is not running")
    let file = try log.fullText()
    try require(!file.contains("hunter2"), "secret kept out of the file")
    try require(
      file.split(separator: "\n").count == 10
        && file.contains(" error bputil: Authorization failed: refused after "),
      "the file keeps each line with its level and source")

    // Filters and search, as the window applies them.
    try require(
      InstallerLogFormat.visible(entries, filter: .errorsOnly, search: "").count == 5, "errors")
    try require(
      InstallerLogFormat.visible(entries, filter: .errorsAndProgress, search: "").count == 5,
      "progress")
    try require(
      InstallerLogFormat.visible(entries, filter: .all, search: "SECOND").count == 2, "search")
    try require(
      InstallerLogFormat.visible(entries, filter: .all, search: "bputil").count == 10,
      "search matches the source")
    try require(
      InstallerLogFilter.allCases.map(\.title)
        == ["Show Errors Only", "Show Errors and Progress", "Show All Logs"], "titles")
    let running = CommandLog("/usr/bin/kmutil", ["configure-boot"], log: log)
    spin(0.3)
    try require(log.running.map(\.activity) == ["kmutil#2"], "a started command is running")
    running.finish(status: 0)

    // Persisting moves the attempt file without rewriting it later.
    let saved = root.appendingPathComponent("saved-attempt.log")
    log.persist(to: saved)
    let inode =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.systemFileNumber] as! NSNumber
    let started = Date()
    let count = 20000
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      for index in 0..<count { log.appendOutput("readable log output \(index)") }
      log.append("END OF FIRST ATTEMPT")
      group.leave()
    }
    while group.wait(timeout: .now()) != .success { spin(0.02) }
    spin(0.3)
    let elapsed = Date().timeIntervalSince(started)
    let full = try log.fullText()
    try require(
      full.components(separatedBy: "\n").filter { $0.contains("readable log output") }.count
        == count, "full file must retain every line")
    try require(full.hasSuffix(" info  Installer: END OF FIRST ATTEMPT\n"), "file ends")
    try require(
      log.entries.count == log.displayLimit && log.truncated, "live view must remain bounded")
    try require(log.entries.last?.message == "END OF FIRST ATTEMPT", "live view has final line")
    try require(
      zip(log.entries, log.entries.dropFirst()).allSatisfy { $0.sequence < $1.sequence },
      "lines stay in order")
    try require(publications <= Int(ceil(elapsed / 0.2)) + 6, "updates must be coalesced")
    let afterInode =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.systemFileNumber] as! NSNumber
    try require(inode == afterInode, "appending must not rewrite the log file")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as! NSNumber
    try require(permissions.intValue & 0o777 == 0o600, "saved log must stay private")

    // A new attempt starts its own file; the window keeps the session.
    log.append("QUEUED OLD OUTPUT")
    log.beginAttempt()
    log.append("SECOND ATTEMPT")
    spin(0.3)
    try require(log.entries.last?.message == "SECOND ATTEMPT", "session continues in the window")
    let second = try log.fullText()
    try require(
      second.hasSuffix(" info  Installer: SECOND ATTEMPT\n")
        && second.split(separator: "\n").count == 1,
      "new attempt must start a separate full log")
    let previous = try String(contentsOf: saved, encoding: .utf8)
    try require(
      previous.hasSuffix(" info  Installer: QUEUED OLD OUTPUT\n"),
      "retry must leave the previous saved log intact")

    // Long and multi-byte lines stay whole characters and bounded.
    log.append(String(repeating: "🦊éλ", count: 2_000))
    spin(0.3)
    let long = log.entries.last?.message ?? ""
    try require(
      long.count == InstallerLog.maximumMessageCharacters && !long.contains("\u{FFFD}"),
      "lines are bounded on characters")
    let document = InstallerLogFormat.document(
      Array(log.entries.suffix(1)), filter: .all, search: "fox")
    try require(document.contains("Filter: Show All Logs, matching “fox”"), "saved header")
    print(
      "PASS \(count) lines in \(String(format: "%.3f", elapsed))s; \(publications) UI publications; levels, redaction, filters, search, running commands, bounded view, complete append-only file, attempt isolation, permissions"
    )
  }
  static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { fatalError(message) }
  }
}
