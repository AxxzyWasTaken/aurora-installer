/// Says why Create Account is unavailable, for a field the person has typed
/// into. `validName` and `validPassword` are the account installer's own rules,
/// so this only explains them; it never decides what is accepted.
enum RecoveryAccountForm {
  static let usernameProblem =
    "Choose another username: up to 31 characters, starting with a–z, using only a–z, 0–9, “-” or “_”."
  static let passwordProblem = "Use a password without line breaks."
  static let mismatch = "The passwords don’t match."

  static func problem(
    username: String, password: String, confirmation: String,
    validName: (String) -> Bool, validPassword: (String) -> Bool
  ) -> String? {
    if !username.isEmpty && !validName(username) { return usernameProblem }
    if !password.isEmpty && !validPassword(password) { return passwordProblem }
    // Wait until the retyped password is as long as the first, or already
    // differs, so a half-typed confirmation is not reported.
    if !confirmation.isEmpty && confirmation != password
      && (confirmation.count >= password.count || !password.hasPrefix(confirmation))
    {
      return mismatch
    }
    return nil
  }
}
