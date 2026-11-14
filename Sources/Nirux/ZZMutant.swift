import Foundation

// DO NOT MERGE. A revert switched on by the environment, for the proof
// that the tests of a task's sub-task tools fail without each change.
func ZZ(_ name: String) -> Bool {
    ProcessInfo.processInfo.environment["NIRUX_ZZ_MUTANT"] == name
}
