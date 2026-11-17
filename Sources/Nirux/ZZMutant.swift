import Foundation

/// DO NOT MERGE: the flake gate's mutants (scripts/mutants-class.sh): a
/// reverted line runs while NIRUX_ZZ_MUTANT names it.
func ZZ(_ name: String) -> Bool { ProcessInfo.processInfo.environment["NIRUX_ZZ_MUTANT"] == name }
