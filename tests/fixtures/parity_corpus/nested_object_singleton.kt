// A nested `object` (in a class OR an interface) referenced as
// `Outer.Obj` resolves to the singleton instance, not a bare class
// token — so member calls, `is` checks, and `::class` all work.
interface TimeSource {
    fun markNow(): Long
    object Monotonic : TimeSource {
        override fun markNow(): Long = 42L
    }
    companion object {
        val Default: TimeSource = Monotonic
    }
}

class Outer {
    object Tool { fun run(): String = "tool" }
}

fun main() {
    println(TimeSource.Monotonic.markNow())
    println(TimeSource.Default.markNow())
    val ts: TimeSource = TimeSource.Monotonic
    println(ts is TimeSource.Monotonic)
    println(TimeSource.Monotonic::class.simpleName)
    println(Outer.Tool.run())
}
