#if os(macOS)
  import Foundation

  /// One artifact transfer as the Installer Log records it: where it comes
  /// from (host and file only), its size, the bytes so far with rate and time
  /// left, and how it was verified. Progress lines come at each tenth of the
  /// file; detail lines at most every two seconds.
  final class InstallerDownloadLog: @unchecked Sendable {
    static let detailIntervalNanoseconds: UInt64 = 2_000_000_000
    static let source = "download"

    private let buffer: InstallerLogBuffer
    private let fileName: String
    private let total: UInt64
    private let digest: String
    let activity: String
    private let lock = NSLock()
    private let started = InstallerTimingRecorder.now()
    private var baseline: (bytes: UInt64, at: UInt64)?
    private var lastDetail: UInt64 = 0
    private var lastTenth = 0
    private var latest: UInt64 = 0
    private var assembling = false
    private var finished = false

    private init(buffer: InstallerLogBuffer, artifact: PinnedInstallerArtifact) {
      self.buffer = buffer
      fileName = InstallerLogRedactor.line(artifact.fileName)
      total = artifact.expectedSizeBytes
      digest = artifact.expectedDigest
      activity = "download:" + InstallerLogRedactor.source(artifact.fileName)
    }

    /// Starts recording a transfer, or nil when no log is active.
    static func begin(_ artifact: PinnedInstallerArtifact) -> InstallerDownloadLog? {
      guard let buffer = InstallerLog.current else { return nil }
      return InstallerDownloadLog(buffer: buffer, artifact: artifact)
    }

    /// The artifact is already in the staging folder and still matches.
    func reused() {
      finish(
        .progress,
        "Using \(fileName) already downloaded (\(InstallerLog.bytes(total))); "
          + "size and SHA-256 match the signed catalog (\(Self.short(digest)))")
    }

    func copiedFromBundle() {
      finish(
        .progress,
        "Copied \(fileName) from the offline installer (\(InstallerLog.bytes(total))); "
          + "size and SHA-256 match the signed catalog (\(Self.short(digest)))")
    }

    /// The transfer starts. `parts` is how many separately fetched parts the
    /// file has, and `kept` how many of them are already verified on disk.
    func downloading(from url: URL, parts: Int = 0, kept: Int = 0) {
      var message = "Downloading \(fileName) (\(InstallerLog.bytes(total))) from \(Self.host(url))"
      if parts > 0 {
        message += " in \(parts) parts"
        if kept > 0 { message += ", \(kept) already verified" }
      }
      buffer.append(.progress, source: Self.source, message, activity: activity)
    }

    func part(_ index: Int, of count: Int, from url: URL, bytes: UInt64) {
      buffer.append(
        .debug, source: Self.source,
        "Fetching part \(index + 1) of \(count) of \(fileName) (\(InstallerLog.bytes(bytes))) "
          + "from \(Self.host(url))/\(url.lastPathComponent)")
    }

    /// Wraps the stager's progress handler so every event is also measured.
    func observing(_ handler: ArtifactStagingProgressHandler?) -> ArtifactStagingProgressHandler {
      { [self] event in
        observe(event)
        handler?(event)
      }
    }

    func observe(_ event: ArtifactStagingProgress) {
      let now = InstallerTimingRecorder.now()
      var line: (InstallerLogLevel, String)?
      lock.withLock {
        guard !finished else { return }
        switch event.phase {
        case .downloading:
          let bytes = min(event.bytesCompleted, total)
          latest = max(latest, bytes)
          if baseline == nil {
            baseline = (bytes, now)
            lastDetail = now
            lastTenth = total > 0 ? Int(bytes * 10 / total) : 0
            return
          }
          let tenth = total > 0 ? Int(latest * 10 / total) : 0
          if tenth > lastTenth && tenth < 10 {
            lastTenth = tenth
            lastDetail = now
            line = (.progress, status(now: now))
          } else if now - lastDetail >= Self.detailIntervalNanoseconds {
            lastDetail = now
            line = (.debug, status(now: now))
          }
        case .assembling:
          guard !assembling else { return }
          assembling = true
          line = (.progress, "Assembling and checking \(fileName)")
        case .verified:
          return
        }
      }
      if let line { buffer.append(line.0, source: Self.source, line.1, activity: activity) }
    }

    /// Size and digest matched: the transfer is done.
    func verified() {
      let elapsed = InstallerTimingRecorder.now() - started
      var message =
        "Verified \(fileName): size and SHA-256 match the signed catalog (\(Self.short(digest)))"
      if let rate = lock.withLock({ averageRate(now: InstallerTimingRecorder.now()) }) {
        message +=
          "; \(InstallerLog.duration(nanoseconds: elapsed)) at \(InstallerLog.bytes(rate))/s"
      }
      finish(.progress, message)
    }

    func failed(_ error: any Error) {
      finish(.error, "\(fileName) failed: \(PayloadPrefetchFailure.reason(for: error))")
    }

    private func finish(_ level: InstallerLogLevel, _ message: String) {
      let first = lock.withLock {
        defer { finished = true }
        return !finished
      }
      guard first else { return }
      buffer.append(level, source: Self.source, message, activity: activity, closesActivity: true)
    }

    private func averageRate(now: UInt64) -> UInt64? {
      guard let baseline, now > baseline.at, latest > baseline.bytes else { return nil }
      let seconds = Double(now - baseline.at) / 1_000_000_000
      guard seconds >= 0.5 else { return nil }
      return UInt64(Double(latest - baseline.bytes) / seconds)
    }

    private func status(now: UInt64) -> String {
      let percent = total > 0 ? Int(latest * 100 / total) : 0
      var text =
        "\(fileName): \(InstallerLog.bytes(latest)) of \(InstallerLog.bytes(total)) (\(percent)%)"
      if let rate = averageRate(now: now), rate > 0 {
        text += " · \(InstallerLog.bytes(rate))/s"
        let left = min((total - min(total, latest)) / rate, 359_999)
        text += " · about \(InstallerLog.duration(nanoseconds: left * 1_000_000_000)) left"
      }
      return text
    }

    /// The host and file of a URL, never its query or credentials.
    static func host(_ url: URL) -> String {
      InstallerLogRedactor.source(url.host ?? "unknown host")
    }

    static func short(_ digest: String) -> String {
      let hex = digest.split(separator: ":").last.map(String.init) ?? digest
      let algorithm = digest.contains(":") ? String(digest.prefix { $0 != ":" }) + ":" : ""
      return hex.count > 16 ? algorithm + hex.prefix(12) + "…" + hex.suffix(4) : digest
    }
  }
#endif
