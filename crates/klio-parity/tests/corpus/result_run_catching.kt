fun parse(s: String): Int = s.toInt()

fun main() {
    val good = runCatching { parse("42") }
    val bad = runCatching { parse("oops") }
    println(good.isSuccess)
    println(good.getOrNull())
    println(bad.isFailure)
    println(bad.exceptionOrNull() != null)

    val mapped = good.map { it * 2 }
    println(mapped.getOrNull())

    val mc = good.mapCatching { it.toString().toInt() / 0 }
    println(mc.isFailure)

    var saw = ""
    bad.onFailure { saw = "fail" }.onSuccess { saw = "ok" }
    println(saw)
}
