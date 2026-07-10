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

// Nested parenthesized annotated form (`icon: (@Marked (() -> Unit))?`) and
// the non-nullable parenthesized form in a param list, plus an annotated
// setter parameter — the ButtonGroup/Slider/DatePicker shapes.
fun renderIcon(icon: (@Marked (() -> Unit))?, track: @Marked ((Int) -> Unit)) {
    icon?.invoke()
    track(5)
}

class Holder {
    var millis: Long? = null
        set(@Suppress("AutoBoxing") value) {
            field = value
        }
}

fun main() {
    renderLeading { c -> println("leading $c") }
    renderLeading()
    renderTrailing { x, y -> println("trailing $x $y") }
    renderPlain { it + 1 }
    renderIcon({ println("icon") }) { n -> println("track $n") }
    val h = Holder()
    h.millis = 99L
    println("millis=${h.millis}")
}
