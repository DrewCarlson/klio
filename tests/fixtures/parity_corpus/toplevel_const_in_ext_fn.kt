// A bare top-level `const val` / `val` referenced inside an
// extension-function body resolves to the top-level binding, not a
// (missing) member of the extension receiver.
const val LIMIT: Long = 1_000L
val LABEL: String = "cap"

fun Long.clamped(): Long = if (this > LIMIT) LIMIT else this
fun Long.tagged(): String = "$LABEL($this)"

fun main() {
    println(5L.clamped())
    println(5_000L.clamped())
    println(42L.tagged())
}
