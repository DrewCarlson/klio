// Kotlin binds a TRAILING LAMBDA to the LAST parameter, whatever gap the named
// arguments leave in between. A constructor is no different from a function
// here: `Panel("p", n = 11) { … }` puts the block in `content` and defaults
// `flag` — it must not drop the block into the first free slot and shift
// everything after it.
class Panel(
    val label: String,
    val flag: Boolean = false,
    val n: Int = 3,
    val content: () -> String,
)

fun panel(
    label: String,
    flag: Boolean = false,
    n: Int = 3,
    content: () -> String,
): String = "$label flag=$flag n=$n body=${content()}"

fun main() {
    // Named argument skips a defaulted parameter, trailing lambda fills the last.
    val p = Panel("panel", n = 11) { "body" }
    println("ctor: label=${p.label} flag=${p.flag} n=${p.n} body=${p.content()}")

    // The same shape through a function, which must agree.
    println("fun : ${panel("panel", n = 11) { "body" }}")

    // No gap: every parameter supplied positionally, block last.
    val q = Panel("full", true, 7) { "b2" }
    println("ctor: label=${q.label} flag=${q.flag} n=${q.n} body=${q.content()}")

    // Defaults all the way, block last.
    val r = Panel("bare") { "b3" }
    println("ctor: label=${r.label} flag=${r.flag} n=${r.n} body=${r.content()}")
}
