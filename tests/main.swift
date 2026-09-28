import Foundation

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String) {
    if ok { passed += 1; print("  PASS  \(label)") } else { failed += 1; print("  FAIL  \(label)") }
}

print("Runner")
check(true, "el runner compila NotchDrop.swift real")

print("\nRESULTADO: \(passed) pass / \(failed) fail")
exit(failed == 0 ? 0 : 1)
