// Named parameters inside function types, including the parenthesized
// nullable form after a type-use annotation — the ContextMenuUi.kt shape:
// `leadingIcon: @Composable ((iconColor: Color) -> Unit)? = null`.
annotation class Marked

fun renderLeading(leading: @Marked ((iconColor: Int) -> Unit)? = null) {
    leading?.invoke(7)
}

fun renderTrailing(trailing: ((x: Int, y: String) -> Unit)? = null) {
    trailing?.invoke(2, "b")
}

fun renderPlain(plain: (count: Int) -> Int) {
    println("plain=${plain(41)}")
}

fun main() {
    renderLeading { c -> println("leading $c") }
    renderLeading()
    renderTrailing { x, y -> println("trailing $x $y") }
    renderPlain { it + 1 }
}
