# Installer Log

**Window → Installer Log** (⌘L) opens a live log of what the installer and its privileged helper are doing. It is modelled on the Installer Log of Apple's Install macOS app in macOS Recovery: a separate window with a level filter, a search field and **Save…**, and timestamped monospaced lines that follow new output unless you scroll up.

## What it shows

Each line has a time, a source and a message. Sources are `Installer` for the app, `helper` for the privileged helper, and the name of a tool or subsystem (`diskutil`, `download`, `journal`, `firmware`). Lines from the helper carry a `helper/` prefix, for example `helper/diskutil`.

- **Phases.** Each change of screen phase (inspection, plan preparation, plan review, authorization, installation, Recovery handoff, failure), with the time spent in the phase it left.
- **Steps.** Every step the helper measures for its timing journal (`InstallerPerformance`): credential validation, plan import, each native preflight stage (`apfs`, `stub_files`, `os_partitions`, `payload_images`, `esp_files`, `finishing`), each disk change, finishing and the Recovery handoff, with start, end and duration. Outermost steps are progress lines; the steps inside them are debug lines; a step that stops is an error.
- **Journal.** Each record the execution journal gains. Checkpoints and the completion are progress lines.
- **Downloads.** Host and file (never the query), size, progress at each tenth with rate and time left, debug lines every two seconds, retries, cache hits, bundled copies, and verification against the signed catalog. The helper's firmware range reads from Apple's servers are debug lines; their retries are progress lines.
- **Commands.** Every tool the app or helper starts (`diskutil`, `bless`, `hdiutil`, `codesign`, `newfs_msdos`, `launchctl`, the stub decoder): the redacted command line, exit status and duration. A failure adds the last three lines of the tool's standard error at error level. The footer lists commands and transfers still running.
- **Errors.** The failure the person sees, its technical cause, and the helper's own failure notice: reason, exit status, whether the disk is unchanged, and the per-stage summary.

## Levels

| Filter | Shows |
| --- | --- |
| Show Errors Only | errors |
| Show Errors and Progress (default) | errors and progress |
| Show All Logs | everything, including commands, journal detail and download detail |

The window remembers the filter. Search matches message and source, ignoring case, and highlights matches. **Save…** writes the lines currently shown, with full dates, to a file you choose.

## Redaction

Every line passes through `InstallerLogRedactor` before it is stored, in both processes, and again when the app receives the helper's lines.

- The helper's diagnostics redaction (`EngineStandardErrorRedactor`) applies: exact secrets, credential-named `key=value` and `key: value` pairs (withheld to the end of the line), bearer and basic tokens, bytes literals, terminal escapes and control characters.
- The macOS password is removed wherever it appears. The helper registers it for the duration of a job, and the app for the duration of authorization and execution (`InstallerLog.redacting`).
- In command lines, the value after an account or credential flag (`--user`, `-passphrase`, `--token` and similar) is withheld. Native stages hand passwords to tools on stdin, so this is defense in depth.
- URLs keep their scheme, host and path. Credentials, query and fragment are removed, and an Apple FCS key name is withheld.
- The person's home folder becomes `~`, and any other home folder loses its account name.
- The full redacted standard-error tail stays in the helper's root-only diagnostics, as before. The log carries only the last three lines, each cut to one printable line of at most 200 characters, the treatment a failure summary already gets. Observation tokens, catalog signatures and job tickets are never logged.

## From the helper to the app

The helper keeps each job's lines in a bounded in-memory ring (4,000 lines; the last four jobs). The app reads them through the existing job status call, which it already polls while it watches a job. The status request carries an optional `logSequence` cursor, and the snapshot carries an optional `log` batch of at most 512 lines. Older helpers never send the batch, older apps never send the cursor, and both sides ignore what they don't know, as `preparationStep` already does. The helper never waits on the app: a full ring drops its oldest line, and the app writes a line saying how many it missed.

Work the helper does outside a job (removal, Recovery account updates) is not logged into any job.

## Saved log

The live app also appends every level to `~/Library/Logs/Aurora Installer/installer.log` (0600 in a 0700 folder), starting each launch with a header naming the app version, Mac model and macOS version. A failed install therefore leaves its whole log behind. At 4 MB the file moves to `installer.1.log`, and two older files are kept, so the log never takes more than 12 MB. Writing happens on its own queue. If the disk falls behind by 2 MB, lines are dropped and their count is written once it catches up. The file is never written through a symbolic link. The helper's root-only diagnostics are unchanged.

Simulations, previews and renders keep the log in memory only, so a rehearsal never reads as a real installation.

## Renders

`--render-flow=DIRECTORY` (debug builds) ends with the log window, frozen mid-download, while the helper runs a command, and after a failed Recovery handoff, at each filter level, with search, in light and dark appearance. See [Simulation.md](Simulation.md#flow-renders).
