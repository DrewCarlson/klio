// Overload resolution must be default-argument-aware: a call that
// supplies fewer arguments than a candidate's parameter count is
// still applicable when every omitted trailing parameter has a
// default. `sysProp("k", 32)` must bind the 4-parameter
// `(String, Int, Int = 1, Int = 99): Int` overload — not the
// 2-parameter `(String, Boolean)` / `(String, String)` siblings —
// and the omitted `lo` / `hi` fill from their defaults. An exact
// arity match is still preferred over a defaulted one.
fun sysProp(name: String, default: Boolean): Boolean = default
fun sysProp(name: String, default: String): String = default
fun sysProp(name: String, default: Int, lo: Int = 1, hi: Int = 99): Int {
    val v = default
    return if (v < lo) lo else if (v > hi) hi else v
}
fun sysProp(name: String, default: Int, lo: Int): String = "3arg:$lo"

fun main() {
    println(sysProp("a", 32))        // Int 4-param, defaults lo=1 hi=99 -> 32
    println(sysProp("b", 250))       // clamped to hi=99
    println(sysProp("c", -7))        // clamped to lo=1
    println(sysProp("flag", true))   // Boolean overload
    println(sysProp("s", "str"))     // String overload
    println(sysProp("d", 5, 4))      // exact 3-arg overload wins -> "3arg:4"
}
