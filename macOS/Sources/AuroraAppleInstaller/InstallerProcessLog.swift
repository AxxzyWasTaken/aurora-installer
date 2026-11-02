#if os(macOS)
  import Foundation
  import RecoveryAccountCore

  /// A tool the installer started, as the Installer Log records it: the
  /// redacted command, how it ended and how long it took. A tool that fails
  /// adds the last few lines of its standard error at error level, each
  /// redacted and cut to one short printable line, as a failure summary is;
  /// the full tail stays in the helper's root-only diagnostics. Nothing is
  /// recorded when no log is active.
  struct InstallerProcessLog: Sendable {
    static let standardErrorLines = 3
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counter: UInt64 = 0

    let buffer: InstallerLogBuffer
    let tool: String
    let command: String
    let number: UInt64
    let start: UInt64
    let secrets: [Data]

    var activity: String { "\(tool)#\(number)" }

    static func begin(_ executable: String, _ arguments: [String], secrets: [Data] = []) -> Self? {
      guard let buffer = InstallerLog.current else { return nil }
      let secrets = secrets + InstallerLog.secrets
      let number = lock.withLock {
        counter += 1
        return counter
      }
      let started = Self(
        buffer: buffer,
        tool: InstallerLogRedactor.source(URL(fileURLWithPath: executable).lastPathComponent),
        command: InstallerLogRedactor.command(executable, arguments, secrets: secrets),
        number: number, start: InstallerTimingRecorder.now(), secrets: secrets)
      buffer.append(
        .debug, source: started.tool, "Started #\(number): \(started.command)",
        activity: started.activity)
      return started
    }

    private var elapsed: String {
      let now = InstallerTimingRecorder.now()
      return InstallerLog.duration(nanoseconds: now - min(start, now))
    }

    /// How the tool ended. `standardError` is what it wrote there, when kept.
    /// A probe whose non-zero status is an answer, not a fault, passes
    /// `failureLevel: .debug`.
    func end(
      status: Int32, signaled: Bool = false, standardError: Data? = nil, truncated: Bool = false,
      failureLevel: InstallerLogLevel = .error
    ) {
      guard signaled || status != 0 else {
        buffer.append(
          .debug, source: tool, "Exited 0 after \(elapsed) (#\(number))", activity: activity,
          closesActivity: true)
        return
      }
      let how = signaled ? "Terminated by signal \(status)" : "Exited with status \(status)"
      buffer.append(
        failureLevel, source: tool, "\(how) after \(elapsed) (#\(number)): \(command)",
        activity: activity, closesActivity: true)
      for line in Self.tail(standardError, truncated: truncated, secrets: secrets) {
        buffer.append(failureLevel, source: tool, "stderr: " + line, secrets: secrets)
      }
    }

    func end(
      _ process: Process, standardError: Data? = nil, truncated: Bool = false,
      failureLevel: InstallerLogLevel = .error
    ) {
      end(
        status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal,
        standardError: standardError, truncated: truncated, failureLevel: failureLevel)
    }

    /// The tool could not be started, or was stopped before it finished.
    func failed(_ reason: String) {
      buffer.append(
        .error, source: tool, "\(reason) after \(elapsed) (#\(number)): \(command)",
        activity: activity, closesActivity: true)
    }

    /// The last non-empty lines of a tool's standard error, redacted as the
    /// helper's diagnostics are and cut as a failure summary is.
    static func tail(_ data: Data?, truncated: Bool, secrets: [Data]) -> [String] {
      guard let data, !data.isEmpty else { return [] }
      let text = EngineStandardErrorRedactor.redact(data, truncated: truncated, secrets: secrets)
      let lines = text.split(whereSeparator: \.isNewline)
        .map { EngineFailureNotice.sanitizedSummary(String($0)) }
        .filter { !$0.isEmpty }
      return Array(lines.suffix(standardErrorLines))
    }
  }

  /// Each record the execution journal gains, as a log line. Checkpoints and
  /// the completion are progress; the rest is detail.
  enum InstallerJournalLog {
    static func record(sequence: Int, type: String, name: String) {
      let level: InstallerLogLevel =
        type == "checkpoint" || type == "completion" ? .progress : .debug
      InstallerLog.record(
        level, source: "journal",
        "Journal #\(sequence) \(type)" + (name.isEmpty ? "" : ": \(name)"))
    }
  }

  /// `AccountNativeCommand.checked`, recorded in the Installer Log.
  enum InstallerLoggedCommand {
    @discardableResult
    static func checked(
      _ executable: String, _ arguments: [String], input: Data = Data(), timeout: UInt32 = 60
    ) throws -> Data {
      let log = InstallerProcessLog.begin(
        executable, arguments, secrets: input.isEmpty ? [] : [input])
      let result: AccountCommandResult
      do {
        result = try AccountNativeCommand.run(
          executable, arguments, input: input, timeout: timeout)
      } catch {
        log?.failed("Couldn't finish")
        throw error
      }
      log?.end(status: result.status)
      guard result.status == 0 else {
        throw AccountSetupFailure(
          "\(URL(fileURLWithPath: executable).lastPathComponent) could not complete the account setup."
        )
      }
      return result.output
    }
  }
#endif
