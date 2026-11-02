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

    /// The message as lines safe to keep and show; empty lines are dropped.
    public static func lines(_ message: String, secrets: [Data]) -> [String] {
      var text = EngineStandardErrorRedactor.redact(
        Data(message.utf8), truncated: false, secrets: secrets)
      text = urls(in: text)
      text = homePaths(in: text)
      return text.split(whereSeparator: \.isNewline).compactMap { line in
        let cleaned = String(
          line.replacingOccurrences(of: "\t", with: " ")
            .prefix(InstallerLogBuffer.maximumMessageCharacters)
        ).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
      }
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

    /// A command line as the log shows it. The value after a flag that names
    /// an account or credential, and any credential-named `key=value`
    /// argument, is withheld. Secrets never travel in arguments here, as
    /// native stages hand them to tools on stdin; this is defense in depth.
    public static func command(
      _ executable: String, _ arguments: [String], secrets: [Data] = []
    ) -> String {
      var shown = [quoted(executable)]
      var withholdNext = false
      for argument in arguments {
        if withholdNext {
          shown.append(redaction)
          withholdNext = false
          continue
        }
        if isValueFlag(argument) {
          withholdNext = true
          shown.append(argument)
        } else if let separator = argument.firstIndex(of: "="),
          isCredentialName(String(argument[..<separator]))
        {
          shown.append(String(argument[...separator]) + redaction)
        } else {
          shown.append(quoted(argument))
        }
      }
      return line(shown.joined(separator: " "), secrets: secrets)
    }

    private static let valueFlagNames: Set<String> = [
      "user", "username", "password", "passwd", "pass", "passphrase", "secret", "token",
      "key", "pin", "credential", "credentials", "auth", "authorization",
    ]

    static func isValueFlag(_ argument: String) -> Bool {
      guard argument.hasPrefix("-") else { return false }
      let name = argument.drop { $0 == "-" }.lowercased()
      return valueFlagNames.contains(name)
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
