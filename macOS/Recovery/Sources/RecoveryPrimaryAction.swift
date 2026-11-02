/// The Recovery flow's steps, in order.
enum Stage: Int, CaseIterable {
  case welcome, installing, account, complete
}

/// What a step's primary button is waiting for. While it waits, the button is
/// disabled and a spinner turns to its left; VoiceOver hears `announcement`.
enum RecoveryWait: Equatable {
  case verifying, creatingAccount, restarting

  var announcement: String {
    switch self {
    case .verifying: return "Checking this Mac…"
    case .creatingAccount: return "Creating the recovery account…"
    case .restarting: return "Restarting…"
    }
  }
}

/// The primary button of one step: Continue or Restore, Create Account, or
/// Restart. Derived from the model's flags so the window and its tests agree
/// on when the button waits. Its title never changes while it waits, so the
/// button keeps its size and place.
struct RecoveryPrimaryAction: Equatable {
  var title: String
  var isEnabled: Bool
  var wait: RecoveryWait?

  struct Inputs {
    var stage: Stage
    var recoveryInterface = false
    var checkingEnvironment = false
    var creatingAccount = false
    var restartingWithoutAccount = false
    var restartingCompletedSetup = false
    var accountAlreadyStarted = false
    var accountFormValid = false
    var offersAccount = false
  }

  /// nil for the installing step, which shows progress instead of a button.
  static func resolve(_ inputs: Inputs) -> RecoveryPrimaryAction? {
    let wait: RecoveryWait?
    if inputs.checkingEnvironment {
      wait = .verifying
    } else if inputs.creatingAccount {
      wait = .creatingAccount
    } else if inputs.restartingCompletedSetup || inputs.restartingWithoutAccount {
      wait = .restarting
    } else {
      wait = nil
    }
    switch inputs.stage {
    case .welcome:
      return RecoveryPrimaryAction(
        title: inputs.recoveryInterface ? "Restore" : "Continue", isEnabled: wait == nil,
        wait: wait)
    case .installing:
      return nil
    case .account:
      return RecoveryPrimaryAction(
        title: inputs.accountAlreadyStarted ? "Continue" : "Create Account",
        isEnabled: wait == nil && inputs.accountFormValid, wait: wait)
    case .complete:
      return RecoveryPrimaryAction(
        title: inputs.offersAccount ? "Create Recovery Account" : "Restart",
        isEnabled: wait == nil, wait: wait)
    }
  }
}
