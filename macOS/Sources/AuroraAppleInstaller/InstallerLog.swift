#if os(macOS)
  import AuroraFirmware
  import Darwin
  import Foundation

  /// How much an Installer Log line matters. The log window shows every level
  /// up to the one chosen, as Apple's Installer Log does.
  public enum InstallerLogLevel: Int, Codable, Sendable, CaseIterable, Comparable {
    case error = 0
    case progress = 1
    case debug = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// A level this build doesn't know, such as one a newer helper sends,
    /// reads as detail.
    public init(from decoder: any Decoder) throws {
      self = Self(rawValue: try decoder.singleValueContainer().decode(Int.self)) ?? .debug
    }

    /// The word written in saved logs.
    public var label: String {
      switch self {
      case .error: "error"
      case .progress: "info"
      case .debug: "debug"
      }
    }
  }

  /// One line of the Installer Log. Every field is display text: nothing in
  /// it may decide trust, and the message is redacted before it is stored.
  public struct InstallerLogEntry: Codable, Equatable, Sendable, Identifiable {
    public let sequence: UInt64
    public let time: Date
    public let level: InstallerLogLevel
    /// The process or subsystem, such as `Installer`, `helper` or `diskutil`.
    public let source: String
    public let message: String
    /// Names a command or transfer that is under way; the entry with the same
    /// name and `closesActivity` ends it.
    public let activity: String?
    public let closesActivity: Bool

    public var id: UInt64 { sequence }

    public init(
      sequence: UInt64, time: Date, level: InstallerLogLevel, source: String, message: String,
      activity: String? = nil, closesActivity: Bool = false
    ) {
      self.sequence = sequence
      self.time = time
      self.level = level
      self.source = source
      self.message = message
      self.activity = activity
      self.closesActivity = closesActivity
    }
  }

  /// The lines after a reader's cursor. `missed` counts lines that fell out of
  /// the buffer before the reader asked for them.
  public struct InstallerLogBatch: Codable, Equatable, Sendable {
    public static let maximumEntries = 512
    /// The most a batch adds to a reply, as JSON.
    public static let maximumBytes = 512 * 1_024

    public let entries: [InstallerLogEntry]
    public let missed: UInt64
    /// The cursor to ask with next time.
    public let cursor: UInt64
    /// The buffer the lines came from; a cursor only means something there.
    public var ring: UUID? = nil
    /// Whether lines after this batch were left for the next request.
    public var more: Bool? = nil

    public init(
      entries: [InstallerLogEntry], missed: UInt64, cursor: UInt64, ring: UUID? = nil,
      more: Bool? = nil
    ) {
      self.entries = entries
      self.missed = missed
      self.cursor = cursor
      self.ring = ring
      self.more = more
    }

    /// An upper bound on an entry's size as JSON, where every `/` may be
    /// escaped and any byte may need escaping.
    static func encodedBytes(_ entry: InstallerLogEntry) -> Int {
      2 * (entry.message.utf8.count + entry.source.utf8.count + (entry.activity?.utf8.count ?? 0))
        + 160
    }
  }

  /// A bounded, thread-safe ring of log lines. Appending never blocks on a
  /// reader: when the ring is full the oldest line is dropped and counted.
  public final class InstallerLogBuffer: @unchecked Sendable {
    /// Each line's message is cut to this many UTF-8 bytes.
    public static let maximumMessageBytes = 2_000

    public let capacity: Int
    /// Names this buffer, so a reader can tell a restarted helper's apart.
    public let identity = UUID()
    private let lock = NSLock()
    private var ring: [InstallerLogEntry] = []
    private var head = 0
    private var nextSequence: UInt64 = 1
    private var droppedCount: UInt64 = 0
    /// Told each line as it is stored, in order. It runs under the buffer's
    /// lock, so it must hand the line on without blocking.
    private let onAppend: (@Sendable (InstallerLogEntry) -> Void)?

    public init(capacity: Int, onAppend: (@Sendable (InstallerLogEntry) -> Void)? = nil) {
      self.capacity = max(1, capacity)
      self.onAppend = onAppend
      ring.reserveCapacity(min(self.capacity, 1_024))
    }

    /// Stores one line, redacting it first. A message with several lines
    /// becomes one entry per non-empty line.
    @discardableResult
    public func append(
      _ level: InstallerLogLevel, source: String, _ message: String, time: Date = Date(),
      activity: String? = nil, closesActivity: Bool = false, secrets: [Data] = []
    ) -> UInt64? {
      let lines = InstallerLogRedactor.lines(message, secrets: secrets)
      let source = InstallerLogRedactor.source(source)
      let activity = activity.map(InstallerLogRedactor.source)
      return lock.withLock {
        var last: UInt64?
        // An activity line with nothing to say still opens or closes it.
        for line in lines.isEmpty && activity != nil ? [""] : lines {
          last = store(
            InstallerLogEntry(
              sequence: 0, time: time, level: level, source: source, message: line,
              activity: activity, closesActivity: closesActivity))
        }
        return last
      }
    }

    /// Stores lines read from another process, such as the helper's. Their
    /// fields are cleaned again here, without `secrets`: the sender is never
    /// trusted to have. Cleaning happens before the lock is taken.
    public func ingest(
      _ entries: [InstallerLogEntry], sourcePrefix: String, secrets: [Data] = []
    ) {
      let prefix = InstallerLogRedactor.source(sourcePrefix)
      var cleaned: [InstallerLogEntry] = []
      for entry in entries.prefix(InstallerLogBatch.maximumEntries) {
        let source = InstallerLogRedactor.source(entry.source)
        for line in InstallerLogRedactor.lines(entry.message, secrets: secrets) {
          cleaned.append(
            InstallerLogEntry(
              sequence: 0, time: entry.time, level: entry.level,
              source: source == prefix ? prefix : prefix + "/" + source, message: line,
              activity: entry.activity.map { prefix + "/" + InstallerLogRedactor.source($0) },
              closesActivity: entry.closesActivity))
        }
      }
      lock.withLock {
        for entry in cleaned { store(entry) }
      }
    }

    #if DEBUG
      /// Whether this thread could take the lock now; for tests.
      var isLocked: Bool {
        guard lock.try() else { return true }
        lock.unlock()
        return false
      }
    #endif

    @discardableResult
    private func store(_ entry: InstallerLogEntry) -> UInt64 {
      let sequence = nextSequence
      nextSequence += 1
      let stored = InstallerLogEntry(
        sequence: sequence, time: entry.time, level: entry.level, source: entry.source,
        message: entry.message, activity: entry.activity, closesActivity: entry.closesActivity)
      if ring.count < capacity {
        ring.append(stored)
      } else {
        ring[head] = stored
        head = (head + 1) % capacity
        droppedCount += 1
      }
      onAppend?(stored)
      return sequence
    }

    /// Lines dropped because the ring was full.
    public var dropped: UInt64 { lock.withLock { droppedCount } }

    /// The sequence of the newest line, or 0 when there is none.
    public var lastSequence: UInt64 { lock.withLock { nextSequence - 1 } }

    /// Every retained line, oldest first.
    public func snapshot() -> [InstallerLogEntry] {
      lock.withLock { ordered() }
    }

    /// Lines newer than `cursor`, at most `limit` of them and `maximumBytes`
    /// of JSON. A cursor read from another `ring` starts from the beginning.
    public func entries(
      after cursor: UInt64, ring reader: UUID? = nil,
      limit: Int = InstallerLogBatch.maximumEntries,
      maximumBytes: Int = InstallerLogBatch.maximumBytes
    ) -> InstallerLogBatch {
      lock.withLock {
        // A cursor past the newest line, or from another ring, came from an
        // earlier buffer, such as a helper that has since restarted.
        let cursor = cursor < nextSequence && (reader == nil || reader == identity) ? cursor : 0
        let oldest = nextSequence - UInt64(ring.count)
        let start = max(cursor + 1, oldest)
        let missed = start > cursor + 1 ? start - (cursor + 1) : 0
        guard start < nextSequence, limit > 0 else {
          return InstallerLogBatch(
            entries: [], missed: missed, cursor: max(cursor, start - 1), ring: identity)
        }
        var taken: [InstallerLogEntry] = []
        var bytes = 0
        for entry in ordered().dropFirst(Int(start - oldest)).prefix(limit) {
          bytes += InstallerLogBatch.encodedBytes(entry)
          guard bytes <= maximumBytes else { break }
          taken.append(entry)
        }
        let next = taken.last?.sequence ?? max(cursor, start - 1)
        return InstallerLogBatch(
          entries: taken, missed: missed, cursor: next, ring: identity,
          more: next + 1 < nextSequence)
      }
    }

    private func ordered() -> [InstallerLogEntry] {
      guard ring.count == capacity, head > 0 else { return ring }
      return Array(ring[head...] + ring[..<head])
    }
  }

  /// Where a process's log lines go. The helper logs each installation job
  /// into its own buffer for the time it runs; the app logs into one buffer
  /// for its whole life.
  public enum InstallerLog {
    @TaskLocal public static var taskBuffer: InstallerLogBuffer?
    /// Secrets the current task knows, such as the macOS password, removed
    /// from every line it logs.
    @TaskLocal public static var secrets: [Data] = []

    private static let lock = NSLock()
    nonisolated(unsafe) private static var processWide: InstallerLogBuffer?

    /// The app's own log. The helper leaves it unset, so work done outside a
    /// job is never logged into a job.
    public static func setProcessBuffer(_ buffer: InstallerLogBuffer?) {
      lock.withLock { processWide = buffer }
    }

    public static var current: InstallerLogBuffer? {
      taskBuffer ?? lock.withLock { processWide }
    }

    /// Runs `body` with its lines, and the firmware transfers it makes, going
    /// to `buffer`, without `secrets` in any of them.
    public static func logging<T>(
      into buffer: InstallerLogBuffer, secrets: [Data] = [],
      isolation: isolated (any Actor)? = #isolation,
      _ body: () async throws -> T
    ) async rethrows -> T {
      try await $taskBuffer.withValue(buffer) {
        try await $secrets.withValue(Self.secrets + secrets) {
          try await FirmwareTransferLog.$observer.withValue(firmwareObserver) {
            try await body()
          }
        }
      }
    }

    /// Runs `body` with the account's password removed from every line it
    /// logs. The password itself stays out of reach of the caller. When
    /// `body` throws, `failure` may describe the error in an error line,
    /// logged inside the same scope so it is redacted too.
    public static func redacting<T>(
      _ authorization: MachineOwnerAuthorization,
      failure: ((any Error) -> String?)? = nil,
      isolation: isolated (any Actor)? = #isolation,
      _ body: () async throws -> T
    ) async throws -> T {
      try await $secrets.withValue(Self.secrets + [authorization.password]) {
        do { return try await body() } catch {
          if let line = failure?(error) { Self.error(line) }
          throw error
        }
      }
    }

    private static let firmwareObserver: @Sendable (FirmwareTransferLog.Level, String) -> Void = {
      level, message in
      let mapped: InstallerLogLevel =
        switch level {
        case .error: .error
        case .progress: .progress
        case .debug: .debug
        }
      record(mapped, source: "firmware", message)
    }

    public static func record(
      _ level: InstallerLogLevel, source: String = defaultSource, _ message: String,
      activity: String? = nil, closesActivity: Bool = false, secrets: [Data] = []
    ) {
      guard let buffer = current else { return }
      buffer.append(
        level, source: source, message, activity: activity, closesActivity: closesActivity,
        secrets: secrets + Self.secrets)
    }

    public static func error(_ message: String, source: String = defaultSource) {
      record(.error, source: source, message)
    }

    public static func progress(_ message: String, source: String = defaultSource) {
      record(.progress, source: source, message)
    }

    public static func debug(_ message: String, source: String = defaultSource) {
      record(.debug, source: source, message)
    }

    /// `helper` in the privileged helper, which alone runs as root, and
    /// `Installer` in the app.
    public static let defaultSource = geteuid() == 0 ? "helper" : "Installer"

    /// A length of time as the log writes it: `0.42 s`, `12.3 s`, `4 min 05 s`.
    public static func duration(nanoseconds: UInt64) -> String {
      let seconds = Double(nanoseconds) / 1_000_000_000
      if seconds < 10 { return String(format: "%.2f s", seconds) }
      if seconds < 60 { return String(format: "%.1f s", seconds) }
      let whole = Int(seconds.rounded())
      return String(format: "%d min %02d s", whole / 60, whole % 60)
    }

    public static func bytes(_ value: UInt64) -> String {
      ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
  }
#endif
