import Foundation

var passed = 0, failed = 0
func check(_ ok: Bool, _ label: String) {
    if ok { passed += 1 } else { failed += 1; print("  FAIL  \(label)") }
}

let app = AppDelegate()
func calc(_ input: String, _ want: Double?, _ label: String? = nil) {
    let got = app.evaluateArithmetic(input)
    let ok = (got == nil && want == nil) || (got != nil && want != nil && abs(got! - want!) < 1e-6)
    check(ok, "\(label ?? "calc") \"\(input)\" -> \(got.map { String($0) } ?? "nil"), want \(want.map { String($0) } ?? "nil")")
}

// ── Currency calculator ─────────────────────────────────────────────────────
print("Calculadora de Currency")
calc("1", 1); calc("25.5", 25.5); calc("25,5", 25.5); calc("  42  ", 42); calc("0", 0)
calc("25*4", 100); calc("1200/3", 400); calc("10+5", 15); calc("10-5", 5)
calc("2+3*4", 14); calc("(2+3)*4", 20); calc("100/4+1", 26); calc("1.5*2", 3); calc("1,5*2", 3)
calc("19.99*3", 59.97); calc("1500+250", 1750); calc("(1200+800)/2", 1000); calc("50*1.16", 58)
for bad in ["", "   ", "abc", "5++", "*5", "5*", "(5+3", "5+3)", "()", "5..3", "FUNCTION(1)", "$(whoami)", "5/0", "1e999"] {
    calc(bad, nil, "inválido")
}
calc("-5", -5); calc("-5+10", 5); calc("10*-2", -20)

print("Separadores de miles y decimales")
calc("1,000", 1000, "miles"); calc("12,345", 12345, "miles"); calc("1,000,000", 1_000_000, "miles")
calc("1,000.50", 1000.5, "miles+decimal"); calc("1.000,50", 1000.5, "miles+decimal es")
calc("1,5", 1.5, "decimal coma"); calc("0,25", 0.25, "decimal coma")
calc("1,000+2,5", 1002.5, "dos números distintos"); calc("2,5*1,000", 2500, "dos números distintos")
calc("1,5+1,5", 3, "regresión: cada número por separado"); calc("1,000+1,000", 2000)
calc("2,500*2", 5000, "miles en operación"); calc("(1,000+500)/3", 500, "miles con paréntesis")
calc("1,0000", 1, "cuatro decimales con coma"); calc("0,500", 0.5, "0,500 es decimal, no miles"); calc("1,00,000", nil, "agrupación irregular")

print("\nRESULTADO: \(passed) pass / \(failed) fail")
exit(failed == 0 ? 0 : 1)
