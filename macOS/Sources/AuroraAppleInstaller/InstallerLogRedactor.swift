#if os(macOS)
  import Foundation

  /// Makes text safe for the Installer Log, which the person can read, save and
  /// share. It applies the helper's diagnostics redaction
  /// (`EngineStandardErrorRedactor`): exact secrets, credential-named
  /// `key=value` pairs, bearer and basic tokens, bytes literals and terminal
  /// escapes. Then it removes what a shared log should not carry:
  /// - a URL keeps its scheme, host and path; credentials, query and fragment
  ///   go, and an Apple FCS key name is withheld;
  /// - the person's home folder becomes `~` and any other home loses its
  ///   account name;
  /// - each line is printable and bounded.
  public enum InstallerLogRedactor {
    public static let redaction = EngineStandardErrorRedactor.redaction
    static let maximumSourceCharacters = 48

    #if DEBUG
      /// Told each time a message is redacted; for tests.
      nonisolated(unsafe) static var willRedact: (() -> Void)?
    #endif

    /// The message as lines safe to keep and show; empty lines are dropped,
    /// and each line is cut to `InstallerLogBuffer.maximumMessageBytes`.
    public static func lines(_ message: String, secrets: [Data]) -> [String] {
      #if DEBUG
        willRedact?()
      #endif
      var text = EngineStandardErrorRedactor.redact(
        Data(message.utf8), truncated: false, secrets: secrets)
      text = urls(in: text)
      text = homePaths(in: text)
      return text.split(whereSeparator: \.isNewline).compactMap { line in
        let cleaned = bounded(
          line.replacingOccurrences(of: "\t", with: " "),
          bytes: InstallerLogBuffer.maximumMessageBytes
        ).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
      }
    }

    /// At most `bytes` of UTF-8, never splitting a character's encoding.
    static func bounded(_ text: String, bytes: Int) -> String {
      var result = String.UnicodeScalarView()
      var count = 0
      for scalar in text.unicodeScalars {
        count += UTF8.width(scalar)
        guard count <= bytes else { break }
        result.append(scalar)
      }
      return String(result)
    }

    /// One redacted line, or the empty string.
    public static func line(_ message: String, secrets: [Data] = []) -> String {
      lines(message, secrets: secrets).joined(separator: " ")
    }

    /// A short source or activity name: letters, digits and `._-/#:` only.
    public static func source(_ value: String) -> String {
      let allowed = value.unicodeScalars.filter {
        $0.isASCII
          && (CharacterSet.alphanumerics.contains($0) || "._-/#: ".unicodeScalars.contains($0))
      }
      let cleaned = String(String.UnicodeScalarView(allowed).prefix(maximumSourceCharacters))
        .trimmingCharacters(in: .whitespaces)
      return cleaned.isEmpty ? "unknown" : cleaned
    }

    /// A command line as the log shows it. Known secrets are removed from
    /// each argument before it is quoted. Everything after a flag that names
    /// a password, passphrase, secret or token, or `-p`, is withheld, since
    /// some tools take several values there (`dscl -passwd user old new`);
    /// the value after an account flag such as `--user` is withheld; so is a
    /// credential-named `key=value`. Native stages hand secrets to tools on
    /// stdin, so this is defense in depth.
    public static func command(
      _ executable: String, _ arguments: [String], secrets: [Data] = []
    ) -> String {
      let texts = secrets.compactMap { String(data: $0, encoding: .utf8) }.filter { !$0.isEmpty }
      func hidden(_ argument: String) -> String {
        texts.reduce(argument) { $0.replacingOccurrences(of: $1, with: redaction) }
      }
      var shown = [quoted(hidden(executable))]
      var withholdNext = false
      for (index, argument) in arguments.enumerated() {
        if withholdNext {
          shown.append(redaction)
          withholdNext = false
        } else if let separator = argument.firstIndex(of: "="),
          isCredentialName(String(argument[..<separator]))
        {
          shown.append(hidden(String(argument[...separator])) + redaction)
        } else if withholdsRest(argument) {
          shown.append(hidden(argument))
          if index + 1 < arguments.count { shown.append(redaction) }
          break
        } else {
          withholdNext = isValueFlag(argument)
          shown.append(quoted(hidden(argument)))
        }
      }
      return line(shown.joined(separator: " "), secrets: secrets)
    }

    private static let valueFlagNames: Set<String> = [
      "user", "username", "pass", "key", "pin", "credential", "credentials", "auth",
      "authorization",
    ]
    private static let secretFlagWords = ["password", "passwd", "passphrase", "secret", "token"]
    /// Flags that say a secret comes on stdin and take no value.
    private static let stdinFlagNames: Set<String> = [
      "stdinpass", "stdinpassphrase", "stdinpassword",
    ]

    static func flagName(_ argument: String) -> String? {
      guard argument.hasPrefix("-"), !argument.contains("=") else { return nil }
      return argument.drop { $0 == "-" }.lowercased()
    }

    static func isValueFlag(_ argument: String) -> Bool {
      flagName(argument).map(valueFlagNames.contains) ?? false
    }

    static func withholdsRest(_ argument: String) -> Bool {
      guard let name = flagName(argument), !stdinFlagNames.contains(name) else { return false }
      return name == "p" || secretFlagWords.contains { name.contains($0) }
    }

    static func isCredentialName(_ name: String) -> Bool {
      let lowered = name.lowercased()
      return [
        "password", "passwd", "passphrase", "secret", "token", "credential", "apikey", "auth",
      ]
      .contains { lowered.contains($0) }
    }

    private static func quoted(_ argument: String) -> String {
      guard argument.isEmpty || argument.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" })
      else { return argument }
      return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: URLs

    private static let urlPattern = try! NSRegularExpression(
      pattern:
        #"(?i)\b([a-z][a-z0-9+.-]*)://([^\s/?#"'<>]*)([^\s?#"'<>]*)(\?[^\s#"'<>]*)?(#[^\s"'<>]*)?"#
    )

    static func urls(in text: String) -> String {
      let source = text as NSString
      let matches = urlPattern.matches(
        in: text, range: NSRange(location: 0, length: source.length))
      guard !matches.isEmpty else { return text }
      var result = ""
      var last = 0
      for match in matches {
        result += source.substring(
          with: NSRange(location: last, length: match.range.location - last))
        func group(_ index: Int) -> String? {
          let range = match.range(at: index)
          return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        let scheme = group(1) ?? ""
        // Everything up to the last `@` is user information, even when a
        // password in it holds a `/`.
        var location = (group(2) ?? "") + (group(3) ?? "")
        if let at = location.lastIndex(of: "@") {
          location = String(location[location.index(after: at)...])
        }
        if let keys = location.range(of: "/fcs-keys/") {
          location = String(location[..<keys.upperBound]) + redaction
        }
        result += scheme + "://" + location
        if group(4) != nil { result += "?" + redaction }
        last = match.range.location + match.range.length
      }
      result += source.substring(from: last)
      return result
    }

    // MARK: Home folders

    private static let homeDirectory: String? = {
      let home = NSHomeDirectory()
      return home.hasPrefix("/Users/") && home.count > "/Users/".count ? home : nil
    }()

    private static let otherHome = try! NSRegularExpression(
      pattern: #"/Users/(?!Shared(?:/|\b))[^/\s"'<>:]+"#)

    static func homePaths(in text: String, home: String? = homeDirectory) -> String {
      var text = text
      if let home {
        text = text.replacingOccurrences(of: home + "/", with: "~/")
        text = text.replacingOccurrences(
          of: NSRegularExpression.escapedPattern(for: home) + #"(?=$|[\s"'<>:])"#, with: "~",
          options: .regularExpression)
      }
      return otherHome.stringByReplacingMatches(
        in: text, range: NSRange(location: 0, length: (text as NSString).length),
        withTemplate: "/Users/[user]")
    }
  }
#endif
