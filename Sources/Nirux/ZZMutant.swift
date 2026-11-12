import Foundation

// DO NOT MERGE. A revert switched on by the environment, for the flake
// gate's proof that TurnQuestionFlowTests fails without each shell change.
func ZZ(_ name: String) -> Bool {
    ProcessInfo.processInfo.environment["NIRUX_ZZ_MUTANT"] == name
}
