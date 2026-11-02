#if os(macOS)
  import AuroraAppleInstallerTrustCore
  import Foundation

  /// The session's phases as Installer Log lines: one line each time the
  /// flow moves to another phase, with the time spent in the one it left. A
  /// failure names its real cause and the remedy at error level.
  struct InstallerSessionLog {
    private var kind = ""
    private var since = ContinuousClock.now

    mutating func entered(_ phase: InstallerSessionPhase) {
      let next = Self.kind(of: phase)
      guard next != kind else { return }
      let elapsed = since.duration(to: .now)
      let left = Self.title(ofKind: kind)
      kind = next
      since = .now
      // An instant step, such as leaving the welcome page, needs no timing.
      let timing =
        elapsed < .milliseconds(50)
        ? "" : left.map { " (\($0) took \(Self.seconds(elapsed)))" } ?? ""
      for (index, line) in Self.lines(for: phase).enumerated() {
        InstallerLog.record(line.0, source: "Installer", line.1 + (index == 0 ? timing : ""))
      }
    }

    private static func seconds(_ duration: Duration) -> String {
      let (whole, attoseconds) = duration.components
      return InstallerLog.duration(
        nanoseconds: UInt64(max(0, whole)) * 1_000_000_000
          + UInt64(max(0, attoseconds / 1_000_000_000)))
    }

    /// A key that changes only when the flow moves on. A new plan for the
    /// same review, such as after a size change, is a new key.
    private static func kind(of phase: InstallerSessionPhase) -> String {
      switch phase {
      case .inspecting: "inspecting"
      case .unsupported: "unsupported"
      case .welcome: "welcome"
      case .existingInstallRefused: "existing"
      case .partitions: "partitions"
      case .preparingPlan: "preparing"
      case .planPrepared(let plan, _), .planReview(let plan, _): "plan:" + plan.bindingDigest
      case .awaitingInstall: "approved"
      case .installing: "installing"
      case .awaitingRecovery: "recovery"
      case .done: "done"
      case .failed: "failed"
      }
    }

    private static func title(ofKind key: String) -> String? {
      if key.isEmpty { return nil }
      if key.hasPrefix("plan:") { return "plan review" }
      let titles = [
        "inspecting": "inspection", "welcome": "welcome",
        "existing": "existing-installation choice", "partitions": "Partitions on this Mac",
        "preparing": "plan preparation", "approved": "authorization",
        "installing": "installation", "recovery": "Recovery handoff",
      ]
      return titles[key]
    }

    private static func lines(for phase: InstallerSessionPhase) -> [(InstallerLogLevel, String)] {
      switch phase {
      case .inspecting:
        return [(.progress, "Inspecting this Mac")]
      case .unsupported(let failure):
        return failureLines("Can’t install on this Mac", failure)
      case .welcome(let host):
        return [(.progress, "Ready to install: \(host.chipAndSpace)")]
      case .existingInstallRefused(let host):
        return [
          (.progress, "Found \(host.existingInstalls.count) existing Aurora installation(s)")
        ]
      case .partitions(_, let layout):
        return [
          (
            .progress,
            "Showing Partitions on this Mac: \(layout.rows.count) entries, "
              + "\(layout.options.count) place(s) for another installation"
          )
        ]
      case .preparingPlan:
        return [(.progress, "Preparing the installation plan")]
      case .planPrepared(let plan, _), .planReview(let plan, _):
        var line =
          "Plan ready: \(PlainLanguage.bytes(plan.auroraBytes)) for Aurora "
          + "(\(PlainLanguage.bytes(plan.minimumBytes)) to \(PlainLanguage.bytes(plan.maximumBytes)))"
        if !plan.targetDescription.isEmpty { line += " · \(plan.targetDescription)" }
        if !plan.releaseDescription.isEmpty { line += " · \(plan.releaseDescription)" }
        return [(.progress, line)]
      case .awaitingInstall(_, let helper, _):
        return [(.progress, "Plan approved; installation service is \(helper.status)")]
      case .installing:
        return [(.progress, "Installation started")]
      case .awaitingRecovery(let handoff):
        return [(.progress, "Disk changes finished. Next: \(handoff.headline)")]
      case .done(let completion):
        return [(.progress, "\(completion.headline) \(completion.subheadline)")]
      case .failed(let failure):
        return failureLines(failure.headline, failure)
      }
    }

    private static func failureLines(_ headline: String, _ failure: FailureDisplay)
      -> [(InstallerLogLevel, String)]
    {
      var lines: [(InstallerLogLevel, String)] = [
        (.error, headline == failure.headline ? headline : "\(headline): \(failure.headline)")
      ]
      if !failure.plainDetail.isEmpty { lines.append((.error, failure.plainDetail)) }
      if let technical = failure.technicalDetail, !technical.isEmpty {
        lines.append((.error, "Cause: \(technical)"))
      }
      if let remedy = failure.remedy, !remedy.isEmpty {
        lines.append((.progress, "What to do: \(remedy)"))
      }
      return lines
    }
  }
#endif
