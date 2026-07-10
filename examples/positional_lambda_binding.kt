// Two positional lambdas with a defaulted third lambda parameter bind
// positionally — the trailing-lambda shift only fires when the callable
// does not fit its positional slot.

fun render(
    leading: (Int) -> Unit,
    trailing: (Int, String) -> Unit,
    plain: ((Int) -> Int)? = null,
) {
    leading(7)
    trailing(41, "x")
    println("plain=${plain?.invoke(1)}")
}

fun withMsg(message: String? = null, block: () -> Int): Int {
    println("msg=$message")
    return block()
}

fun gap(first: (Int) -> Int = { it }, block: () -> String): String = block() + first(1)

fun main() {
    render({ n -> println("leading $n") }, { a, b -> println("trailing $a $b") })
    println("r=" + withMsg { 42 })
    println("g=" + gap { "ok" })
}
