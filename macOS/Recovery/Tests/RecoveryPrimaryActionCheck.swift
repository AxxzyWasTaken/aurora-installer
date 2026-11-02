@main struct Check {
  typealias Inputs = RecoveryPrimaryAction.Inputs

  static func resolve(_ inputs: Inputs) -> RecoveryPrimaryAction {
    guard let action = RecoveryPrimaryAction.resolve(inputs) else {
      preconditionFailure("\(inputs.stage) has no primary button")
    }
    return action
  }

  static func main() {
    // Welcome: Continue (or Restore) waits, disabled, for the environment check.
    var welcome = Inputs(stage: .welcome)
    precondition(resolve(welcome) == .init(title: "Continue", isEnabled: true, wait: nil))
    welcome.checkingEnvironment = true
    precondition(resolve(welcome) == .init(title: "Continue", isEnabled: false, wait: .verifying))
    welcome.recoveryInterface = true
    precondition(resolve(welcome) == .init(title: "Restore", isEnabled: false, wait: .verifying))
    precondition(RecoveryPrimaryAction.resolve(Inputs(stage: .installing)) == nil)

    // Account: the title stays "Create Account" while it waits.
    var account = Inputs(stage: .account, accountFormValid: true)
    precondition(resolve(account) == .init(title: "Create Account", isEnabled: true, wait: nil))
    account.creatingAccount = true
    precondition(
      resolve(account) == .init(title: "Create Account", isEnabled: false, wait: .creatingAccount))
    account.creatingAccount = false
    account.restartingWithoutAccount = true
    precondition(resolve(account).wait == .restarting && !resolve(account).isEnabled)
    account = Inputs(stage: .account, accountAlreadyStarted: true, accountFormValid: false)
    precondition(resolve(account) == .init(title: "Continue", isEnabled: false, wait: nil))

    // Complete: Restart waits for either restart path, including the deferred account.
    var complete = Inputs(stage: .complete)
    precondition(resolve(complete) == .init(title: "Restart", isEnabled: true, wait: nil))
    complete.restartingCompletedSetup = true
    precondition(resolve(complete) == .init(title: "Restart", isEnabled: false, wait: .restarting))
    complete = Inputs(stage: .complete, restartingWithoutAccount: true)
    precondition(resolve(complete).wait == .restarting && !resolve(complete).isEnabled)
    complete = Inputs(stage: .complete, offersAccount: true)
    precondition(resolve(complete).title == "Create Recovery Account")

    // Every wait has something to tell VoiceOver.
    for wait in [RecoveryWait.verifying, .creatingAccount, .restarting] {
      precondition(wait.announcement.hasSuffix("…") && wait.announcement.count > 3)
    }

    print("PASS primary buttons wait disabled with a steady title")
  }
}
