#if DEBUG && os(macOS)
  import AuroraAppleInstallerTrustCore
  import Foundation

  /// Installer Log lines shaped like the live installer's and its helper's,
  /// so the log window can be rehearsed. Hosts, files and numbers are
  /// fictitious; nothing here runs a command or touches a disk.
  enum SimulatedLog {
    static let host = "releases.aurorasilicon.example"
    static let payload = "aurora-simulated.img.zst"
    static let job = "3f2a91c0"

    static func line(
      _ level: InstallerLogLevel, _ source: String, _ message: String, activity: String? = nil,
      closes: Bool = false
    ) {
      InstallerLog.current?.append(
        level, source: source, message, activity: activity, closesActivity: closes)
    }

    static func started(
      _ source: String, _ number: Int, _ executable: String, _ arguments: [String]
    ) {
      line(
        .debug, source,
        "Started #\(number): \(InstallerLogRedactor.command(executable, arguments))",
        activity: "\(source)#\(number)")
    }

    static func exited(
      _ source: String, _ number: Int, seconds: Double, status: Int32 = 0,
      command: (String, [String])? = nil, stderr: [String] = []
    ) {
      let elapsed = InstallerLog.duration(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard status != 0 else {
        line(
          .debug, source, "Exited 0 after \(elapsed) (#\(number))", activity: "\(source)#\(number)",
          closes: true)
        return
      }
      let shown = command.map { ": " + InstallerLogRedactor.command($0.0, $0.1) } ?? ""
      line(
        .error, source, "Exited with status \(status) after \(elapsed) (#\(number))\(shown)",
        activity: "\(source)#\(number)", closes: true)
      for text in stderr { line(.error, source, "stderr: " + text) }
    }

    static func run(_ number: Int, _ arguments: [String], seconds: Double) {
      started("diskutil", number, "/usr/sbin/diskutil", arguments)
      exited("diskutil", number, seconds: seconds)
    }

    static func inspection(supported: Bool) {
      line(
        .progress, "Installer",
        "This Mac: Mac14,9 (apple,j414s), Apple M2 Pro, macOS 26.1; APFS container disk3 on "
          + "disk0s2, 464 GB free")
      line(.debug, "Installer", "Power: AC power; FileVault on; eligibility: eligible")
      run(1, ["list", "-plist", "internal", "physical"], seconds: 0.21)
      run(2, ["apfs", "list", "-plist"], seconds: 0.34)
      run(3, ["apfs", "resizeContainer", "disk3", "limits", "-plist"], seconds: 0.52)
      line(
        supported ? .progress : .error, "Installer",
        supported
          ? "Disk check: apple,j414s is supported; 0 known installation(s), 1 place(s) Aurora could go"
          : "Disk check: apple,j999 is unsupported")
    }

    static func catalog(channel: ReleaseChannel) {
      line(
        .progress, "Installer",
        "Fetching the signed release catalog for aurora-desktop on the \(channel.rawValue) channel")
      line(
        .progress, "download", "Downloading catalog.json (48 KB) from \(host)",
        activity: "download:catalog.json")
      line(
        .progress, "download",
        "Verified catalog.json: size and SHA-256 match the signed catalog "
          + "(sha256:3f9c0d4e1a2b…7c1e); 0.31 s at 155 KB/s",
        activity: "download:catalog.json", closes: true)
      line(
        .progress, "download",
        "Using engine-metadata.json already downloaded (12 KB); size and SHA-256 match the "
          + "signed catalog (sha256:a41be0c9d722…09fa)")
    }

    static func downloadStarted(total: UInt64) {
      line(
        .progress, "download",
        "Downloading \(payload) (\(InstallerLog.bytes(total))) from \(host) in 4 parts",
        activity: "download:\(payload)")
      for part in 1...3 {
        line(
          .debug, "download",
          "Fetching part \(part) of 4 of \(payload) (1 GB) from \(host)/\(payload).part\(part)")
      }
    }

    static func downloadProgress(_ bytes: Int, of total: UInt64) {
      let completed = UInt64(bytes)
      let rate: UInt64 = 41_800_000
      let left = (total - min(total, completed)) / rate
      let status =
        "\(payload): \(InstallerLog.bytes(completed)) of \(InstallerLog.bytes(total)) "
        + "(\(completed * 100 / total)%) · \(InstallerLog.bytes(rate))/s · about "
        + "\(InstallerLog.duration(nanoseconds: left * 1_000_000_000)) left"
      line(.progress, "download", status, activity: "download:\(payload)")
    }

    static func downloadInterrupted() {
      line(
        .progress, "download",
        "The download was interrupted: The network connection was lost. Trying again in "
          + "5.0 seconds (retry 1 of 6)")
      line(
        .error, "download",
        "\(payload) failed: The download was interrupted: The network connection was lost.",
        activity: "download:\(payload)", closes: true)
    }

    static func downloadMismatch() {
      line(.progress, "download", "Assembling and checking \(payload)")
      line(
        .error, "download",
        "\(payload) failed: The downloaded file does not match the signed release "
          + "(expected simulation-expected, got simulation-corrupt).",
        activity: "download:\(payload)", closes: true)
    }

    static func downloadVerified() {
      line(.progress, "download", "Assembling and checking \(payload)")
      line(
        .progress, "download",
        "Verified \(payload): size and SHA-256 match the signed catalog "
          + "(sha256:9d0e51c2b7aa…e4d2); 1 min 36 s at 41.6 MB/s",
        activity: "download:\(payload)", closes: true)
    }

    static func jobAccepted(_ operation: InstallOperationKind) {
      line(
        .progress, "Installer",
        "Handing the approved plan simulation to the installation service (\(operation))")
      line(
        .progress, "helper",
        "Accepted installation job \(job): \(operation == .install ? "install" : "retry") "
          + "for aurora-desktop")
    }

    static func step(_ name: String, seconds: Double) {
      let title = InstallerStepTitles.title(for: name).map { " (\($0))" } ?? ""
      line(.progress, "helper", "Started \(name)\(title)")
      line(
        .progress, "helper",
        "Finished \(name) in \(InstallerLog.duration(nanoseconds: UInt64(seconds * 1e9)))")
    }

    static func stepStarted(_ name: String) {
      let title = InstallerStepTitles.title(for: name).map { " (\($0))" } ?? ""
      line(.progress, "helper", "Started \(name)\(title)")
    }

    static func stepFinished(_ name: String, seconds: Double) {
      line(
        .progress, "helper",
        "Finished \(name) in \(InstallerLog.duration(nanoseconds: UInt64(seconds * 1e9)))")
    }

    static func stepStopped(_ name: String, seconds: Double) {
      line(
        .error, "helper",
        "Stopped \(name) after \(InstallerLog.duration(nanoseconds: UInt64(seconds * 1e9)))")
    }

    static func spaceRefused() {
      stepStarted("apfs_preflight")
      stepStopped("apfs_preflight", seconds: 0.41)
      let summary = "aurora_execution.ExecutionAdmissionError: approved extent changed"
      line(
        .error, "helper",
        "Installation job \(job) failed (engine, reason approvedSpaceChanged, exit 1, disk "
          + "unchanged): \(summary)")
    }

    private static let resize = (
      "/usr/sbin/diskutil", ["apfs", "resizeContainer", "disk3", "857747943424"]
    )
    private static let decoder = (
      "/Library/PrivilegedHelperTools/aurora-stub-decoder",
      [
        "/private/var/db/aurora-installer/stub/UniversalMac_26.1_Restore.ipsw",
        "sha256:5aa8b12b40e4", "/private/var/db/aurora-installer/stub/root.img",
      ]
    )
    private static let bless = (
      "/usr/sbin/bless",
      ["--setBoot", "--device", "/dev/disk5s1", "--user", "owner", "--stdinpass"]
    )

    /// What the helper is doing while the next journal record is written.
    static func beforeRecord(_ index: Int, scenario: InstallerSimulationScenario) {
      switch index {
      case 3:
        stepStarted("apfs_preparation")
        started("helper/diskutil", 21, resize.0, resize.1)
      case 5:
        stepStarted("stub_files")
        started("helper/aurora-stub-decoder", 22, decoder.0, decoder.1)
      case 7:
        stepStarted("recovery_handoff")
        started("helper/bless", 23, bless.0, bless.1)
      default: break
      }
    }

    static func record(
      _ index: Int, scenario: InstallerSimulationScenario, operation: InstallOperationKind
    ) {
      let types = [
        "inspection", "inventory", "plan", "event", "checkpoint", "event", "checkpoint", "event",
        "checkpoint", "completion",
      ]
      let names = [
        "", "", "", "apfs_preparation_started", "apfs-target-prepared", "stub_and_esp_started",
        "stub-and-esp-installed", "recovery_handoff_started", "recovery-handoff-prepared",
        "awaiting_recovery",
      ]
      guard types.indices.contains(index) else { return }
      if index == 4 { exited("helper/diskutil", 21, seconds: 41.2) }
      if index == 6 { exited("helper/aurora-stub-decoder", 22, seconds: 74.0) }
      if index == 8 { exited("helper/bless", 23, seconds: 3.1) }
      let type = types[index]
      line(
        type == "checkpoint" || type == "completion" ? .progress : .debug, "helper/journal",
        "Journal #\(index + 1) \(type)" + (names[index].isEmpty ? "" : ": \(names[index])"))
      switch index {
      case 4: stepFinished("apfs_preparation", seconds: 41.6)
      case 5 where scenario == .helperFailure:
        exited(
          "helper/aurora-stub-decoder", 22, seconds: 12.4, status: 1, command: decoder,
          stderr: [
            "decode: block 1843 of 9120: checksum mismatch",
            "decode: stopping; partial output removed",
          ])
        stepStopped("stub_files", seconds: 12.6)
        line(.error, "helper", "Installation job \(job) failed (helper, disk may have changed)")
      case 6:
        stepFinished("stub_files", seconds: 74.3)
        for (name, seconds) in [
          ("os_partitions", 1.2), ("payload_images", 38.5), ("esp_files", 2.4),
          ("finishing", 6.8),
        ] {
          step(name, seconds: seconds)
        }
      case 7 where scenario == .recoveryRetry && operation == .install:
        exited(
          "helper/bless", 23, seconds: 2.1, status: 3, command: bless,
          stderr: ["Could not set boot device property: 0xe00002e2"])
        stepStopped("recovery_handoff", seconds: 2.3)
        line(.error, "helper", "Installation job \(job) failed (recovery, disk may have changed)")
      case 8: stepFinished("recovery_handoff", seconds: 3.4)
      default: break
      }
    }
  }
#endif
