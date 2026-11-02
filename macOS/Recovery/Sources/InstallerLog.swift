import Foundation

/// How much an Installer Log line matters. The log window shows every level
/// up to the one chosen, as Apple's Installer Log does.
enum InstallerLogLevel: Int, CaseIterable, Comparable {
  case error = 0
  case progress = 1
  case debug = 2

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  var label: String {
    switch self {
    case .error: "error"
    case .progress: "info"
    case .debug: "debug"
    }
  }
}

/// One line of the log. `activity` names a command that is under way; the
/// line with the same name and `closesActivity` ends it.
struct InstallerLogEntry: Equatable {
  let sequence: Int
  let time: Date
  let level: InstallerLogLevel
  let source: String
  let message: String
  var activity: String? = nil
  var closesActivity = false
}

/// The log window's filter, worded as Apple's Installer Log.
enum InstallerLogFilter: Int, CaseIterable {
  case errorsOnly = 0
  case errorsAndProgress = 1
  case all = 2

  var title: String {
    switch self {
    case .errorsOnly: "Show Errors Only"
    case .errorsAndProgress: "Show Errors and Progress"
    case .all: "Show All Logs"
    }
  }

  var maximumLevel: InstallerLogLevel { InstallerLogLevel(rawValue: rawValue) ?? .debug }

  func admits(_ entry: InstallerLogEntry) -> Bool { entry.level <= maximumLevel }
}

enum InstallerLogFormat {
  /// The lines `filter` admits that contain `search`, ignoring case, in
  /// their message or source.
  static func visible(
    _ entries: [InstallerLogEntry], filter: InstallerLogFilter, search: String
  ) -> [InstallerLogEntry] {
    let needle = search.trimmingCharacters(in: .whitespaces)
    return entries.filter { entry in
      filter.admits(entry)
        && (needle.isEmpty || entry.message.range(of: needle, options: .caseInsensitive) != nil
          || entry.source.range(of: needle, options: .caseInsensitive) != nil)
    }
  }

  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = format
    return formatter
  }
  private static let clockFormatter = formatter("HH:mm:ss.SSS")
  private static let timestampFormatter = formatter("yyyy-MM-dd HH:mm:ss.SSSZ")

  static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
  static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

  /// One line of a saved log: time, level, source, message.
  static func fileLine(_ entry: InstallerLogEntry) -> String {
    let level = entry.level.label.padding(toLength: 5, withPad: " ", startingAt: 0)
    return "\(timestamp(entry.time)) \(level) \(entry.source): \(entry.message)"
  }

  /// A saved log: a header naming what was shown, then the lines.
  static func document(
    _ entries: [InstallerLogEntry], filter: InstallerLogFilter, search: String, now: Date = Date()
  ) -> String {
    var text = "Aurora Installer log (Recovery), saved \(timestamp(now))\nFilter: \(filter.title)"
    if !search.trimmingCharacters(in: .whitespaces).isEmpty { text += ", matching “\(search)”" }
    text += "\n\n"
    for entry in entries { text += fileLine(entry) + "\n" }
    return text
  }
}

/// Makes text safe to show and save: no terminal escapes or control
/// characters, no known secret, and nothing after a credential-named key.
/// Native authorization hands the password to tools through their prompt, so
/// this is defense in depth, as the main installer's log redaction is.
enum InstallerLogRedactor {
  static let redaction = "[redacted]"

  static func lines(_ text: String, secrets: [String] = []) -> [String] {
    var text = text
    for secret in secrets where !secret.isEmpty {
      text = text.replacingOccurrences(of: secret, with: redaction)
    }
    text = text.replacingOccurrences(
      of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    var cleaned = String.UnicodeScalarView()
    for scalar in text.unicodeScalars
    where scalar == "\n" || scalar == "\t"
      || (scalar.value >= 0x20 && scalar.value != 0x7F && !(0x80...0x9F).contains(scalar.value))
    {
      cleaned.append(scalar == "\t" ? " " : scalar)
    }
    text = String(cleaned)
    // Removing escapes can join a secret they had split.
    for secret in secrets where !secret.isEmpty {
      text = text.replacingOccurrences(of: secret, with: redaction)
    }
    text = text.replacingOccurrences(
      of:
        #"(?im)\b([A-Za-z0-9_-]*(?:password|passwd|passphrase|secret|token|credential|api[_-]?key|authorization|bearer|cookie)[A-Za-z0-9_-]*)(\s*[=:]).*$"#,
      with: "$1$2 \(redaction)", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#, with: "$1 \(redaction)",
      options: .regularExpression)
    return text.split(whereSeparator: \.isNewline).compactMap { line in
      let bounded = String(line.prefix(InstallerLog.maximumMessageCharacters))
        .trimmingCharacters(in: .whitespaces)
      return bounded.isEmpty ? nil : bounded
    }
  }

  /// A command line as the log shows it; the value after an account or
  /// credential flag is withheld.
  static func command(_ executable: String, _ arguments: [String]) -> String {
    let flags: Set<String> = [
      "user", "username", "password", "passwd", "pass", "passphrase", "secret", "token", "key",
    ]
    var shown = [executable]
    var withholdNext = false
    for argument in arguments {
      if withholdNext {
        shown.append(redaction)
        withholdNext = false
        continue
      }
      withholdNext =
        argument.hasPrefix("-") && flags.contains(argument.drop { $0 == "-" }.lowercased())
      let quote = argument.isEmpty || argument.contains(" ")
      shown.append(quote ? "'" + argument + "'" : argument)
    }
    return shown.joined(separator: " ")
  }
}

/// Recovery's Installer Log. The file keeps the current attempt in full, one
/// line per entry with its time, level and source; the window gets the
/// newest `displayLimit` lines of the whole session, at most five times a
/// second. Only sanitized, redacted text enters it.
final class InstallerLog {
  static let shared = InstallerLog()
  static let maximumMessageCharacters = 2_000
  var onChange: (() -> Void)?
  /// The newest lines, oldest first, as of the last main-queue update.
  private(set) var entries: [InstallerLogEntry] = []
  /// Older lines no longer shown; the attempt files keep them.
  private(set) var truncated = false
  let displayLimit: Int
  private let directory: URL
  private let lock = NSLock()
  private var lines: [InstallerLogEntry] = []
  private var linesTruncated = false
  private var nextSequence = 1
  private var updateScheduled = false
  private var file: URL?
  private var handle: FileHandle?
  private var temporary = true
  private var storageError: String?

  init(directory: URL = FileManager.default.temporaryDirectory, displayLimit: Int = 5_000) {
    self.directory = directory
    self.displayLimit = max(100, displayLimit)
    beginAttempt()
  }
  deinit { try? handle?.close() }

  /// Starts a new attempt file. The window keeps the session's earlier lines.
  func beginAttempt() {
    lock.lock()
    defer { lock.unlock() }
    try? handle?.close()
    handle = nil
    storageError = nil
    temporary = true
    let path = directory.appendingPathComponent("aurora-installer-" + UUID().uuidString + ".log")
    file = path
    if FileManager.default.createFile(
      atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
    {
      do { handle = try FileHandle(forWritingTo: path) } catch {
        storageError = error.localizedDescription
      }
    } else {
      storageError = "Could not create the attempt log."
    }
    scheduleUpdateLocked()
  }

  func append(
    _ message: String, level: InstallerLogLevel = .progress, source: String = "Installer",
    activity: String? = nil, closesActivity: Bool = false, secrets: [String] = []
  ) {
    let texts = InstallerLogRedactor.lines(message, secrets: secrets)
    let time = Date()
    lock.lock()
    defer { lock.unlock() }
    for text in texts.isEmpty && activity != nil ? [""] : texts {
      let entry = InstallerLogEntry(
        sequence: nextSequence, time: time, level: level, source: source, message: text,
        activity: activity, closesActivity: closesActivity)
      nextSequence += 1
      do {
        try handle?.write(contentsOf: Data((InstallerLogFormat.fileLine(entry) + "\n").utf8))
      } catch { storageError = error.localizedDescription }
      lines.append(entry)
    }
    // Trim in batches so a long run does not shift the array per line.
    if lines.count > displayLimit + displayLimit / 4 {
      lines.removeFirst(lines.count - displayLimit)
      linesTruncated = true
    }
    scheduleUpdateLocked()
  }

  /// Output a command wrote, as detail lines.
  func appendOutput(_ output: String, source: String = "output", secrets: [String] = []) {
    append(output, level: .debug, source: source, secrets: secrets)
  }

  func persist(to url: URL) {
    lock.lock()
    defer { lock.unlock() }
    guard let source = file, source != url else { return }
    do {
      try handle?.synchronize()
      try FileManager.default.copyItem(at: source, to: url)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      guard FileManager.default.contentsEqual(atPath: source.path, andPath: url.path) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let saved = try FileHandle(forWritingTo: url)
      try saved.seekToEnd()
      try handle?.close()
      handle = saved
      file = url
      // Only remove our temporary duplicate after a byte-identical copy.
      if temporary { try? FileManager.default.removeItem(at: source) }
      temporary = false
    } catch { storageError = "Could not save the full log: " + error.localizedDescription }
    scheduleUpdateLocked()
  }

  /// The current attempt's file.
  func fullText() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if let storageError {
      throw NSError(
        domain: "AuroraInstallerLog", code: 1, userInfo: [NSLocalizedDescriptionKey: storageError])
    }
    guard let file else { return "" }
    return try String(contentsOf: file, encoding: .utf8)
  }

  /// Commands still running, oldest first.
  var running: [InstallerLogEntry] {
    var open: [String: InstallerLogEntry] = [:]
    for entry in entries {
      guard let activity = entry.activity else { continue }
      if entry.closesActivity {
        open.removeValue(forKey: activity)
      } else if open[activity] == nil {
        open[activity] = entry
      }
    }
    return open.values.sorted { $0.sequence < $1.sequence }
  }

  private func scheduleUpdateLocked() {
    guard !updateScheduled else { return }
    updateScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      // Read the latest state here, so queued callbacks never publish an
      // older copy or one copy per line.
      var snapshot = self.lines
      if snapshot.count > self.displayLimit {
        snapshot.removeFirst(snapshot.count - self.displayLimit)
      }
      let clipped = self.linesTruncated || self.lines.count > self.displayLimit
      let error = self.storageError
      self.updateScheduled = false
      self.lock.unlock()
      if let error, snapshot.last?.message.hasPrefix("Log storage error") != true {
        snapshot.append(
          InstallerLogEntry(
            sequence: (snapshot.last?.sequence ?? 0) + 1, time: Date(), level: .error,
            source: "Installer", message: "Log storage error: " + error))
      }
      if self.entries != snapshot { self.entries = snapshot }
      if self.truncated != clipped { self.truncated = clipped }
      self.onChange?()
    }
  }
}

/// One command in the log: its redacted command line, its output as detail
/// lines, and how it ended. A failure repeats the last lines of its output at
/// error level.
final class CommandLog {
  static let failureLines = 3
  private static let counter = NSLock()
  private static var count = 0

  private let log: InstallerLog
  private let tool: String
  private let activity: String
  private let number: Int
  private let started = Date()
  private let secrets: [String]
  private var previous = ""
  private var partial = ""
  private var recent: [String] = []

  init(
    _ executable: String, _ arguments: [String], secrets: [String] = [],
    log: InstallerLog = .shared
  ) {
    self.log = log
    self.secrets = secrets
    tool = URL(fileURLWithPath: executable).lastPathComponent
    Self.counter.lock()
    Self.count += 1
    number = Self.count
    Self.counter.unlock()
    activity = "\(tool)#\(number)"
    log.append(
      "Started #\(number): " + InstallerLogRedactor.command(executable, arguments),
      level: .debug, source: tool, activity: activity, secrets: secrets)
  }

  /// Takes the command's cumulative output so far.
  func output(_ snapshot: String) {
    guard snapshot != previous else { return }
    if snapshot.hasPrefix(previous) {
      add(String(decoding: snapshot.utf8.dropFirst(previous.utf8.count), as: UTF8.self))
    } else {
      // Preserve diagnostics if a producer revises its output instead
      // of returning the cumulative snapshots used by our PTY helper.
      log.append("Command output revised", level: .debug, source: tool)
      partial = ""
      add(snapshot)
    }
    previous = snapshot
  }

  private func add(_ delta: String) {
    let text = partial + delta
    var pieces = text.components(separatedBy: "\n")
    partial = pieces.removeLast()
    for piece in pieces { emit(piece) }
  }

  private func emit(_ line: String) {
    let cleaned = InstallerLogRedactor.lines(line, secrets: secrets)
    guard !cleaned.isEmpty else { return }
    recent = Array((recent + cleaned).suffix(Self.failureLines))
    for text in cleaned { log.appendOutput(text, source: tool) }
  }

  /// How the command ended. `reason` describes a status that is not an
  /// exit code, such as an authorization failure. Previews pass `elapsed`.
  func finish(status: Int32, reason: String? = nil, elapsed: TimeInterval? = nil) {
    if !partial.isEmpty {
      emit(partial)
      partial = ""
    }
    let seconds = String(format: "%.2f s", elapsed ?? Date().timeIntervalSince(started))
    guard status != 0 else {
      log.append(
        "Exited 0 after \(seconds) (#\(number))", level: .debug, source: tool,
        activity: activity, closesActivity: true)
      return
    }
    log.append(
      "\(reason ?? "Exited with status \(status)") after \(seconds) (#\(number))", level: .error,
      source: tool, activity: activity, closesActivity: true, secrets: secrets)
    for line in recent { log.append("output: " + line, level: .error, source: tool) }
  }
}
